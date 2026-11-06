import Foundation
import Testing

@testable import HardwareControllerMac

struct AskGeminiChatTest {
  @Test(arguments: [
    ("https://gemini.google.com/app", true),
    ("https://accounts.google.com/signin", true),
    ("http://gemini.google.com/app", false),
    ("https://evil.example/gemini.google.com", false),
    ("https://gemini.google.com.evil.example/app", false),
    ("file:///etc/hosts", false),
  ])
  func mainFrameLoadsStayOnAllowedHttpsHosts(_ load: (String, Bool)) {
    #expect(AskGeminiNavigationPolicy.allowsMainFrame(URL(string: load.0)) == load.1)
  }

  @Test
  func missingURLAndHomeAreHandled() {
    #expect(!AskGeminiNavigationPolicy.allowsMainFrame(nil))
    #expect(AskGeminiNavigationPolicy.allowsMainFrame(AskGeminiNavigationPolicy.homeURL))
  }

  @Test
  func onlyAnExplicitSubmittedResultCountsAsSent() {
    #expect(AskGeminiSubmission(scriptResult: "submitted") == .submitted)
    #expect(
      AskGeminiSubmission(scriptResult: "composer not found") == .failed("composer not found"))
    #expect(AskGeminiSubmission(scriptResult: nil) == .failed("no result"))
    #expect(AskGeminiSubmission(scriptResult: 1) == .failed("no result"))
  }
}
