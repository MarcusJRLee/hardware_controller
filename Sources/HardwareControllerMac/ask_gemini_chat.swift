import Foundation
import WebKit

/// The only hosts the Gemini panel loads as a page. Everything else opens in
/// the default browser, so the panel cannot become a general browser.
enum AskGeminiNavigationPolicy {
  static let allowedHosts: Set<String> = [
    "gemini.google.com",
    "accounts.google.com",
    "accounts.youtube.com",
    "myaccount.google.com",
    "www.google.com",
  ]

  static let homeURL: URL = {
    guard let url = URL(string: "https://gemini.google.com/app") else {
      preconditionFailure("The Gemini home URL is a valid literal.")
    }
    return url
  }()

  /// Main-frame loads must stay on HTTPS and an allowed host.
  static func allowsMainFrame(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", let host = url.host() else {
      return false
    }
    return allowedHosts.contains(host)
  }
}

/// Outcome of typing a question into Gemini's composer.
enum AskGeminiSubmission: Equatable {
  case submitted
  case failed(String)

  init(scriptResult: Any?) {
    let text = scriptResult as? String ?? "no result"
    self = text == "submitted" ? .submitted : .failed(text)
  }
}

/// One Gemini chat. Every chat shares the default website data store, so one
/// Google sign-in covers all of them.
@MainActor
final class AskGeminiChat {
  let webView: WKWebView
  var pendingQuestion: String?
  /// Set once a question is submitted, so a later ask never reloads this chat.
  /// Gemini keeps the `/app` path for signed-in chats, so the URL is not proof.
  private(set) var hasSubmitted = false
  /// The last question Gemini did not accept, kept for the clipboard fallback.
  private(set) var lastFailedQuestion: String?
  private var titleObservation: NSKeyValueObservation?

  init(zoom: Double, onTitleChange: @escaping @MainActor () -> Void) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.pageZoom = zoom
    titleObservation = webView.observe(\.title) { _, _ in
      MainActor.assumeIsolated { onTitleChange() }
    }
  }

  var isInUse: Bool {
    hasSubmitted || pendingQuestion != nil
  }

  var title: String {
    let raw = (webView.title ?? "").replacingOccurrences(of: " - Google Gemini", with: "")
    return !isInUse || raw.isEmpty || raw == "Google Gemini" ? "New chat" : raw
  }

  func loadHome() {
    webView.load(URLRequest(url: AskGeminiNavigationPolicy.homeURL))
  }

  /// Types the pending question into Gemini's composer and sends it.
  func submitPending() async -> AskGeminiSubmission? {
    guard let question = pendingQuestion else {
      return nil
    }
    pendingQuestion = nil
    let submission: AskGeminiSubmission
    do {
      // The isolated content world hides this script from page scripts; DOM
      // events still reach Gemini's editor.
      let result = try await webView.callAsyncJavaScript(
        Self.submitScript,
        arguments: ["question": question],
        contentWorld: .defaultClient
      )
      submission = AskGeminiSubmission(scriptResult: result)
    } catch {
      submission = .failed(error.localizedDescription)
    }
    if submission == .submitted {
      hasSubmitted = true
      lastFailedQuestion = nil
    } else {
      lastFailedQuestion = question
    }
    return submission
  }

  /// Depends on Gemini's current composer markup and English "Send message"
  /// label; a redesign fails the submission, never a wrong click.
  private static let submitScript = """
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const deadline = Date.now() + 10000;
    if (location.host !== 'gemini.google.com') return 'not on Gemini';
    let editor = null;
    while (!(editor = document.querySelector('rich-textarea .ql-editor[contenteditable="true"]'))) {
      if (Date.now() > deadline) return 'composer not found';
      await sleep(100);
    }
    editor.replaceChildren(...question.split('\\n').map(line => {
      const paragraph = document.createElement('p');
      paragraph.textContent = line;
      return paragraph;
    }));
    editor.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText'}));
    for (;;) {
      const send = document.querySelector('button[aria-label="Send message"]');
      if (send && !send.disabled && send.getAttribute('aria-disabled') !== 'true') {
        send.click();
        return 'submitted';
      }
      if (Date.now() > deadline) return 'send button not ready';
      await sleep(100);
    }
    """
}
