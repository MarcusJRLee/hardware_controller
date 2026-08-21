import AppKit
import HardwareControllerCore

public enum TranscriptionIndicatorKind: Equatable, Sendable {
  case notReady
  case ready
  case preparing
  case listening
  case finalizing
  case canceling
  case completed
  case blocked
}

public struct TranscriptionIndicatorPresentation:
  Equatable,
  Sendable
{
  public let kind: TranscriptionIndicatorKind
  public let title: String
  public let detail: String?
  public let transcript: String?

  public init(
    kind: TranscriptionIndicatorKind,
    title: String,
    detail: String?,
    transcript: String?
  ) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.transcript = transcript
  }

  public var showsDetails: Bool {
    switch kind {
    case .notReady, .ready, .completed:
      false
    case .preparing, .listening, .finalizing,
      .canceling, .blocked:
      true
    }
  }
}

public enum TranscriptionIndicatorPolicy {
  public static func presentation(
    for snapshot: TranscriptionSnapshot
  ) -> TranscriptionIndicatorPresentation? {
    guard
      !snapshot.showsInlineProvisionalText,
      [.listening, .finalizing].contains(snapshot.phase)
    else {
      return nil
    }

    var transcript = snapshot.finalText
    TranscriptAccumulator.append(
      snapshot.volatileText,
      to: &transcript
    )
    guard !transcript.isEmpty else {
      return nil
    }

    return TranscriptionIndicatorPresentation(
      kind:
        snapshot.phase == .finalizing
        ? .finalizing
        : .listening,
      title:
        snapshot.phase == .finalizing
        ? "Finalizing"
        : "Listening",
      detail: snapshot.targetApplicationName,
      transcript: transcript
    )
  }

  public static func presentation(
    for snapshot: LocalAIDictationSnapshot
  ) -> TranscriptionIndicatorPresentation? {
    let kind: TranscriptionIndicatorKind
    let title: String
    switch snapshot.phase {
    case .preparing:
      (kind, title) = (.preparing, "Preparing Local AI")
    case .listening:
      (kind, title) = (.listening, "Listening")
    case .finalizing:
      (kind, title) = (.finalizing, "Transcribing")
    case .refining:
      (kind, title) = (.finalizing, "Refining")
    case .validating:
      (kind, title) = (.finalizing, "Checking result")
    case .delivering:
      (kind, title) = (.finalizing, "Inserting")
    case .canceling:
      (kind, title) = (.canceling, "Canceling")
    case .idle, .completed, .failed:
      return nil
    }
    return TranscriptionIndicatorPresentation(
      kind: kind,
      title: title,
      detail: snapshot.targetApplicationName,
      transcript:
        snapshot.volatileText.isEmpty
        ? (snapshot.rawText.isEmpty ? nil : snapshot.rawText)
        : snapshot.volatileText
    )
  }
}

@MainActor
public final class TranscriptionIndicatorController {
  private var isRunning = false
  private var anchor: CGPoint?
  private var lastPresentation: TranscriptionIndicatorPresentation?
  private var panel: NSPanel?
  private var contentView: TranscriptionIndicatorContentView?

  public init() {}

  public func start() {
    isRunning = true
  }

  public func stop() {
    isRunning = false
    lastPresentation = nil
    anchor = nil
    panel?.orderOut(nil)
  }

  public func update(
    _ presentation: TranscriptionIndicatorPresentation?,
    anchor: CGPoint?
  ) {
    guard isRunning else {
      return
    }
    guard let presentation else {
      lastPresentation = nil
      self.anchor = nil
      panel?.orderOut(nil)
      return
    }
    if lastPresentation == presentation,
      self.anchor == anchor
    {
      return
    }
    lastPresentation = presentation
    self.anchor = anchor

    let contentView: TranscriptionIndicatorContentView
    if let current = self.contentView {
      contentView = current
      current.update(presentation)
    } else {
      let created = TranscriptionIndicatorContentView(
        presentation: presentation
      )
      self.contentView = created
      contentView = created
    }

    let panel =
      panel
      ?? makePanel(
        contentView: contentView
      )
    self.panel = panel
    let size = TranscriptionIndicatorPlacement.size(
      showsDetails: presentation.showsDetails
    )
    panel.setContentSize(size)
    panel.orderFrontRegardless()
    updatePosition()
  }

  private func makePanel(
    contentView: TranscriptionIndicatorContentView
  ) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(
        origin: .zero,
        size: NSSize(width: 42, height: 42)
      ),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = contentView
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
    ]
    panel.setAccessibilityElement(false)
    return panel
  }

  private func updatePosition() {
    guard let panel else {
      return
    }
    let screen =
      anchor.flatMap { point in
        NSScreen.screens.first {
          $0.frame.contains(point)
        }
      } ?? NSScreen.main
    let origin = TranscriptionIndicatorPlacement.origin(
      caretAnchor: anchor,
      size: panel.frame.size,
      visibleFrame: screen?.visibleFrame
    )
    panel.setFrameOrigin(origin)
  }
}

struct TranscriptionIndicatorPlacement {
  static func size(
    showsDetails: Bool
  ) -> NSSize {
    showsDetails
      ? NSSize(width: 316, height: 48)
      : NSSize(width: 42, height: 42)
  }

  static func origin(
    caretAnchor: CGPoint?,
    size: NSSize,
    visibleFrame: CGRect?
  ) -> CGPoint {
    var origin: CGPoint
    if let caretAnchor {
      origin = CGPoint(
        x: caretAnchor.x + 12,
        y: caretAnchor.y - (size.height / 2)
      )
    } else if let visibleFrame {
      origin = CGPoint(
        x: visibleFrame.midX - (size.width / 2),
        y: visibleFrame.minY + 28
      )
    } else {
      origin = .zero
    }

    if let frame = visibleFrame {
      origin.x = min(
        max(origin.x, frame.minX + 8),
        frame.maxX - size.width - 8
      )
      origin.y = min(
        max(origin.y, frame.minY + 8),
        frame.maxY - size.height - 8
      )
    }
    return origin
  }
}

private final class TranscriptionIndicatorContentView: NSView {
  private let badgeView = NSView()
  private let imageView = NSImageView()
  private let titleField = NSTextField(labelWithString: "")
  private let detailField = NSTextField(labelWithString: "")
  private var presentation: TranscriptionIndicatorPresentation

  override var isFlipped: Bool {
    true
  }

  init(presentation: TranscriptionIndicatorPresentation) {
    self.presentation = presentation
    super.init(frame: .zero)

    wantsLayer = true
    setAccessibilityElement(false)
    autoresizingMask = [.width, .height]

    badgeView.wantsLayer = true
    badgeView.setAccessibilityElement(false)
    addSubview(badgeView)

    imageView.imageScaling = .scaleProportionallyDown
    imageView.setAccessibilityElement(false)
    badgeView.addSubview(imageView)

    titleField.font = .systemFont(
      ofSize: 12,
      weight: .semibold
    )
    titleField.lineBreakMode = .byTruncatingTail
    titleField.setAccessibilityElement(false)
    addSubview(titleField)

    detailField.font = .systemFont(ofSize: 11)
    detailField.textColor = .secondaryLabelColor
    detailField.lineBreakMode = .byTruncatingTail
    detailField.setAccessibilityElement(false)
    addSubview(detailField)

    update(presentation)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func update(
    _ presentation: TranscriptionIndicatorPresentation
  ) {
    self.presentation = presentation
    titleField.stringValue = presentation.title
    detailField.stringValue =
      presentation.transcript
      ?? presentation.detail
      ?? ""
    titleField.isHidden = !presentation.showsDetails
    detailField.isHidden = !presentation.showsDetails
    imageView.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(
        pointSize: 14,
        weight: .bold
      )
    )
    updateColors()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let badgeSize: CGFloat = 32
    let badgeOrigin =
      presentation.showsDetails
      ? CGPoint(x: 8, y: 8)
      : CGPoint(
        x: (bounds.width - badgeSize) / 2,
        y: (bounds.height - badgeSize) / 2
      )
    badgeView.frame = CGRect(
      origin: badgeOrigin,
      size: CGSize(
        width: badgeSize,
        height: badgeSize
      )
    )
    imageView.frame = badgeView.bounds.insetBy(
      dx: 8,
      dy: 8
    )

    guard presentation.showsDetails else {
      return
    }
    let textX: CGFloat = 50
    let textWidth = max(0, bounds.width - textX - 10)
    titleField.frame = CGRect(
      x: textX,
      y: 6,
      width: textWidth,
      height: 16
    )
    detailField.frame = CGRect(
      x: textX,
      y: 24,
      width: textWidth,
      height: 15
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    let tint = tintColor
    let increasedContrast =
      NSWorkspace.shared
      .accessibilityDisplayShouldIncreaseContrast
    layer?.backgroundColor =
      NSColor.windowBackgroundColor
      .withAlphaComponent(0.97)
      .cgColor
    layer?.cornerRadius =
      presentation.showsDetails ? 16 : 21
    layer?.borderColor =
      tint.withAlphaComponent(
        increasedContrast ? 0.9 : 0.45
      ).cgColor
    layer?.borderWidth = increasedContrast ? 2 : 1

    badgeView.layer?.backgroundColor =
      NSColor.windowBackgroundColor
      .withAlphaComponent(0.97)
      .cgColor
    badgeView.layer?.cornerRadius = 16
    badgeView.layer?.borderColor = tint.cgColor
    badgeView.layer?.borderWidth =
      increasedContrast ? 3 : 2
    imageView.contentTintColor = tint
    titleField.textColor = .labelColor
  }

  private var tintColor: NSColor {
    switch presentation.kind {
    case .notReady:
      .secondaryLabelColor
    case .ready, .completed:
      NSColor(
        red: 0.18,
        green: 0.82,
        blue: 0.67,
        alpha: 1
      )
    case .preparing, .canceling, .blocked:
      .systemOrange
    case .listening, .finalizing:
      .systemBlue
    }
  }

  private var symbol: String {
    switch presentation.kind {
    case .notReady:
      "mic.slash.fill"
    case .ready:
      "checkmark"
    case .preparing:
      "ellipsis"
    case .listening:
      "waveform"
    case .finalizing:
      "hourglass"
    case .canceling:
      "xmark"
    case .completed:
      "checkmark"
    case .blocked:
      "exclamationmark"
    }
  }
}
