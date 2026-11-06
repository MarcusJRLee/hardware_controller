import AppKit
import CoreGraphics
import HardwareControllerCore
import WebKit
import os

/// A floating panel that never activates this app, so the focused app keeps
/// the keyboard until the user clicks into the panel.
final class AskGeminiOverlayPanel: NSPanel {
  var onCommand: ((AskGeminiPanelCommand) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // Panel shortcuts are taken before the web view sees them, so Gemini cannot
  // consume Control-Tab, Command-digit, or zoom keys.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown,
      let onCommand,
      let command = AskGeminiPanelCommand.command(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags.keyModifiers
      )
    {
      onCommand(command)
      return
    }
    super.sendEvent(event)
  }

  // An accessory panel has no Edit menu, so standard editing shortcuts would
  // never reach the web view. Route them down the responder chain.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard
      let key = event.charactersIgnoringModifiers?.lowercased(),
      let action = Self.editAction(key: key, modifiers: event.modifierFlags.keyModifiers),
      NSApp.sendAction(action, to: nil, from: self)
    else {
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  private static func editAction(key: String, modifiers: Set<KeyModifier>) -> Selector? {
    switch (key, modifiers) {
    case ("c", [.command]): #selector(NSText.copy(_:))
    case ("v", [.command]): #selector(NSText.paste(_:))
    case ("x", [.command]): #selector(NSText.cut(_:))
    case ("a", [.command]): #selector(NSText.selectAll(_:))
    case ("z", [.command]): Selector(("undo:"))
    case ("z", [.command, .shift]): Selector(("redo:"))
    default: nil
    }
  }
}

extension NSEvent.ModifierFlags {
  var keyModifiers: Set<KeyModifier> {
    var modifiers: Set<KeyModifier> = []
    if contains(.command) { modifiers.insert(.command) }
    if contains(.option) { modifiers.insert(.option) }
    if contains(.shift) { modifiers.insert(.shift) }
    if contains(.control) { modifiers.insert(.control) }
    return modifiers
  }
}

/// Owns the Gemini panel: chats as tabs, zoom, and the lock point.
@MainActor
public final class AskGeminiPanelController: NSObject, AskGeminiPresenting {
  private let panel: AskGeminiOverlayPanel
  private let tabStrip = NSStackView()
  private let chatContainer = NSView()
  private let zoomLabel = NSTextField(labelWithString: "")
  private let lockButton = NSButton()
  private let persist: @MainActor (AskGeminiPanelSettings) -> Bool
  private let logger = Logger(
    subsystem: ApplicationIdentity.bundleIdentifier,
    category: "AskGemini"
  )
  private var settings: AskGeminiPanelSettings
  private var chats: [AskGeminiChat] = []
  private var selectedIndex = 0
  private var rememberedFrames: [String: PanelRect] = [:]
  private var lastDisplayID: String?

  /// `persist` saves settings atomically and reports success; the panel
  /// adopts settings only after they are saved.
  public init(
    settings: AskGeminiPanelSettings,
    persist: @escaping @MainActor (AskGeminiPanelSettings) -> Bool
  ) {
    self.settings = settings
    self.persist = persist
    panel = AskGeminiOverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    super.init()
    panel.title = "Gemini"
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.delegate = self
    panel.onCommand = { [weak self] command in
      MainActor.assumeIsolated { self?.handle(command) }
    }
    buildLayout()
  }

  // MARK: Asking

  /// Opens the panel without activating this app and sends the question in a
  /// fresh chat, reusing an unused chat when one exists.
  public func present(question: String) async {
    let index = chats.firstIndex { !$0.isInUse } ?? addChat()
    let chat = chats[index]
    chat.pendingQuestion = question
    select(index)
    show()
    // A fresh load guarantees an empty composer; submission waits for it.
    chat.loadHome()
  }

  private func submitPending(in chat: AskGeminiChat) async {
    guard let submission = await chat.submitPending() else {
      return
    }
    switch submission {
    case .submitted:
      panel.title = "Gemini"
    case .failed(let reason):
      // Typed fallback: the question is never lost; the user can paste it.
      logger.error("Gemini submission failed: \(reason, privacy: .public)")
      if let question = chat.lastFailedQuestion {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question, forType: .string)
      }
      panel.title = "Gemini · Couldn't send. Your question is on the clipboard."
    }
    renderTabStrip()
  }

  // MARK: Layout

  private func buildLayout() {
    let content = NSView()
    tabStrip.orientation = .horizontal
    tabStrip.spacing = 2
    tabStrip.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    tabStrip.setHuggingPriority(.defaultLow, for: .horizontal)
    zoomLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    zoomLabel.textColor = .secondaryLabelColor
    lockButton.isBordered = false
    lockButton.target = self
    lockButton.action = #selector(lockClicked)
    lockButton.menu = lockMenu()
    for view in [tabStrip, chatContainer, zoomLabel, lockButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
      tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor, constant: -8),
      tabStrip.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
      lockButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      lockButton.centerYAnchor.constraint(equalTo: tabStrip.centerYAnchor),
      zoomLabel.trailingAnchor.constraint(equalTo: lockButton.leadingAnchor, constant: -8),
      zoomLabel.centerYAnchor.constraint(equalTo: tabStrip.centerYAnchor),
      chatContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
      chatContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      chatContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      chatContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    panel.contentView = content
    renderZoomLabel()
    renderLockButton()
  }

  // MARK: Chats

  @discardableResult
  private func addChat() -> Int {
    let chat = AskGeminiChat(zoom: settings.zoom) { [weak self] in
      self?.renderTabStrip()
    }
    chat.webView.navigationDelegate = self
    chat.webView.uiDelegate = self
    chat.loadHome()
    chats.append(chat)
    renderTabStrip()
    return chats.count - 1
  }

  private func select(_ index: Int) {
    guard chats.indices.contains(index) else {
      return
    }
    selectedIndex = index
    for view in chatContainer.subviews {
      view.removeFromSuperview()
    }
    let webView = chats[index].webView
    webView.translatesAutoresizingMaskIntoConstraints = false
    chatContainer.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: chatContainer.topAnchor),
      webView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor),
    ])
    if panel.isKeyWindow {
      panel.makeFirstResponder(webView)
    }
    renderTabStrip()
  }

  private func close(_ index: Int) {
    guard chats.indices.contains(index) else {
      return
    }
    chats[index].webView.removeFromSuperview()
    chats.remove(at: index)
    guard !chats.isEmpty else {
      // Closing the last chat hides the panel; the next ask starts fresh.
      panel.orderOut(nil)
      renderTabStrip()
      return
    }
    // Keep the same chat selected when an earlier one closes.
    select(index < selectedIndex ? selectedIndex - 1 : min(selectedIndex, chats.count - 1))
  }

  private func handle(_ command: AskGeminiPanelCommand) {
    switch command {
    case .newChat:
      select(addChat())
    case .closeChat:
      close(selectedIndex)
    case .nextChat where !chats.isEmpty:
      select((selectedIndex + 1) % chats.count)
    case .previousChat where !chats.isEmpty:
      select((selectedIndex - 1 + chats.count) % chats.count)
    case .selectChat(let index):
      select(index)
    case .lastChat:
      select(chats.count - 1)
    case .zoomIn, .zoomOut:
      if let zoom = settings.steppedZoom(increasing: command == .zoomIn) {
        setZoom(zoom)
      }
    case .zoomReset:
      setZoom(1.0)
    case .nextChat, .previousChat:
      break
    }
  }

  private func renderTabStrip() {
    for view in tabStrip.arrangedSubviews {
      view.removeFromSuperview()
    }
    for (index, chat) in chats.enumerated() {
      let isSelected = index == selectedIndex
      let title = chat.title
      let button = NSButton(title: title, target: self, action: #selector(chatClicked(_:)))
      button.tag = index
      button.isBordered = false
      button.lineBreakMode = .byTruncatingTail
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isSelected ? .semibold : .regular
          ),
          .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
      )
      button.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
      button.setAccessibilityLabel("Chat \(index + 1): \(title)")
      button.setAccessibilityValue(isSelected ? "Selected" : nil)
      let closeButton = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
        target: self,
        action: #selector(closeClicked(_:))
      )
      closeButton.tag = index
      closeButton.isBordered = false
      closeButton.contentTintColor = .tertiaryLabelColor
      closeButton.setAccessibilityLabel("Close chat \(index + 1)")
      tabStrip.addArrangedSubview(button)
      tabStrip.addArrangedSubview(closeButton)
    }
    let addButton = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
      target: self,
      action: #selector(addClicked)
    )
    addButton.isBordered = false
    addButton.contentTintColor = .secondaryLabelColor
    addButton.setAccessibilityLabel("New chat")
    tabStrip.addArrangedSubview(addButton)
  }

  @objc private func chatClicked(_ sender: NSButton) { select(sender.tag) }
  @objc private func closeClicked(_ sender: NSButton) { close(sender.tag) }
  @objc private func addClicked() { select(addChat()) }

  // MARK: Zoom

  private func setZoom(_ zoom: Double) {
    var candidate = settings
    candidate.zoom = zoom
    adopt(candidate)
    for chat in chats {
      chat.webView.pageZoom = settings.zoom
    }
    renderZoomLabel()
  }

  private func renderZoomLabel() {
    let percent = Int((settings.zoom * 100).rounded())
    // Shown only away from 100%, so the bar stays quiet by default.
    zoomLabel.stringValue = percent == 100 ? "" : "\(percent)%"
    zoomLabel.setAccessibilityLabel("Zoom \(percent) percent")
  }

  // MARK: Lock point

  /// Click sets the lock point when none exists, otherwise returns the panel
  /// to it. Option-click sets it to the current spot.
  @objc private func lockClicked() {
    let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
    if optionHeld || settings.lockPoint == nil {
      setLockPointHere()
    } else {
      moveToLockPoint()
    }
  }

  private func lockMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [
      ("Set Lock Point Here", #selector(setLockPointHere)),
      ("Move to Lock Point", #selector(moveToLockPoint)),
      ("Clear Lock Point", #selector(clearLockPoint)),
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      menu.addItem(item)
    }
    return menu
  }

  @objc private func setLockPointHere() {
    let frame = PanelRect(panel.frame)
    guard let display = AskGeminiPanelPlacement.display(containing: frame, in: Self.displays())
    else {
      return
    }
    var candidate = settings
    candidate.lockPoint = AskGeminiLockPoint(frame: frame, on: display)
    adopt(candidate)
  }

  @objc private func moveToLockPoint() {
    guard
      let lockPoint = settings.lockPoint,
      let display = Self.displays().first(where: { $0.id == lockPoint.displayID })
    else {
      return
    }
    panel.setFrame(
      NSRect(lockPoint.frame(on: display)),
      display: true,
      animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    renderLockButton()
  }

  @objc private func clearLockPoint() {
    var candidate = settings
    candidate.lockPoint = nil
    adopt(candidate)
  }

  private func renderLockButton() {
    let state = AskGeminiPanelPlacement.lockState(
      of: PanelRect(panel.frame),
      settings: settings,
      displays: Self.displays()
    )
    let symbol: String
    let tint: NSColor
    let help: String
    switch state {
    case .unset:
      (symbol, tint, help) = ("lock.open", .tertiaryLabelColor, "Set lock point here")
    case .atLockPoint:
      (symbol, tint, help) = (
        "lock.fill", .labelColor, "At lock point. Option-click to set it here."
      )
    case .away:
      (symbol, tint, help) = (
        "lock.open", .secondaryLabelColor, "Move to lock point. Option-click to set it here."
      )
    }
    lockButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    lockButton.contentTintColor = tint
    lockButton.toolTip = help
    lockButton.setAccessibilityLabel(help)
  }

  /// Persists before adopting, so the panel never shows unsaved settings.
  private func adopt(_ candidate: AskGeminiPanelSettings) {
    if persist(candidate) {
      settings = candidate
    }
    renderLockButton()
  }

  // MARK: Placement

  private func show() {
    let displays = Self.displays()
    if let placement = AskGeminiPanelPlacement.openingFrame(
      settings: settings,
      displays: displays,
      activeDisplayID: Self.activeDisplayID(in: displays),
      lastDisplayID: lastDisplayID,
      rememberedFrames: rememberedFrames
    ) {
      panel.setFrame(NSRect(placement.frame), display: false)
      lastDisplayID = placement.displayID
    }
    panel.orderFrontRegardless()
    renderLockButton()
  }

  private func rememberFrame() {
    let frame = PanelRect(panel.frame)
    if let display = AskGeminiPanelPlacement.display(containing: frame, in: Self.displays()) {
      rememberedFrames[display.id] = frame
      lastDisplayID = display.id
    }
    renderLockButton()
  }

  private static func displays() -> [AskGeminiDisplay] {
    NSScreen.screens.compactMap { screen in
      displayID(of: screen).map {
        AskGeminiDisplay(
          id: $0, frame: PanelRect(screen.frame), visibleFrame: PanelRect(screen.visibleFrame))
      }
    }
  }

  private static func displayID(of screen: NSScreen) -> String? {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else {
      return nil
    }
    return CFUUIDCreateString(nil, uuid) as String
  }

  /// The display under the focused app's front window, else under the
  /// pointer. Window bounds need no Screen Recording permission.
  private static func activeDisplayID(in displays: [AskGeminiDisplay]) -> String? {
    let pointer = NSEvent.mouseLocation
    let pointerDisplay = AskGeminiPanelPlacement.display(
      containing: PanelRect(x: pointer.x, y: pointer.y, width: 1, height: 1),
      in: displays
    )
    guard
      let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]],
      let primaryHeight = NSScreen.screens.first?.frame.height
    else {
      return pointerDisplay?.id
    }
    for window in windows {
      guard
        window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
        window[kCGWindowLayer as String] as? Int == 0,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds)
      else {
        continue
      }
      // Window-server bounds use a top-left origin on the primary display.
      let frame = PanelRect(
        x: rect.minX,
        y: primaryHeight - rect.maxY,
        width: rect.width,
        height: rect.height
      )
      return AskGeminiPanelPlacement.display(containing: frame, in: displays)?.id
        ?? pointerDisplay?.id
    }
    return pointerDisplay?.id
  }

  private func chat(for webView: WKWebView) -> AskGeminiChat? {
    chats.first { $0.webView === webView }
  }
}

extension AskGeminiPanelController: NSWindowDelegate {
  public func windowDidMove(_ notification: Notification) { rememberFrame() }
  public func windowDidResize(_ notification: Notification) { rememberFrame() }
}

extension AskGeminiPanelController: WKNavigationDelegate, WKUIDelegate {
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
    guard let chat = chat(for: webView) else {
      return
    }
    Task { await submitPending(in: chat) }
    renderTabStrip()
  }

  public func webView(
    _ webView: WKWebView,
    decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard action.targetFrame?.isMainFrame ?? true else {
      decisionHandler(.allow)
      return
    }
    if AskGeminiNavigationPolicy.allowsMainFrame(action.request.url) {
      decisionHandler(.allow)
      return
    }
    // Links out of Gemini open in the default browser, never in the panel.
    if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
    decisionHandler(.cancel)
  }

  /// Sign-in popups load in place instead of opening another window.
  public func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if AskGeminiNavigationPolicy.allowsMainFrame(action.request.url) {
      webView.load(action.request)
    } else if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
      NSWorkspace.shared.open(url)
    }
    return nil
  }
}

extension PanelRect {
  init(_ rect: NSRect) {
    self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
  }
}

extension NSRect {
  init(_ rect: PanelRect) {
    self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }
}
