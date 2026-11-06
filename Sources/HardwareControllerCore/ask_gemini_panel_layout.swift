import Foundation

/// A screen rectangle in AppKit's global coordinates (origin bottom-left of
/// the primary display). Core stays free of CoreGraphics.
public struct PanelRect: Equatable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Double { x + width }
  public var maxY: Double { y + height }

  var isUsable: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
  }

  /// Overlapping area, or zero when the rectangles do not overlap.
  func overlapArea(with other: PanelRect) -> Double {
    let width = min(maxX, other.maxX) - max(x, other.x)
    let height = min(maxY, other.maxY) - max(y, other.y)
    return width > 0 && height > 0 ? width * height : 0
  }

  /// Equal within a tolerance, because AppKit rounds window frames.
  func matches(_ other: PanelRect, tolerance: Double = 1) -> Bool {
    abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
      && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
  }
}

/// A display the Gemini panel can open on, described without AppKit.
public struct AskGeminiDisplay: Equatable, Sendable {
  /// Stable across reconnects and arrangement changes (the display UUID).
  public let id: String
  public let frame: PanelRect
  public let visibleFrame: PanelRect

  public init(id: String, frame: PanelRect, visibleFrame: PanelRect) {
    self.id = id
    self.frame = frame
    self.visibleFrame = visibleFrame
  }
}

/// Where the panel always opens: one display plus a frame relative to that
/// display's origin, so rearranging displays keeps the spot.
public struct AskGeminiLockPoint: Equatable, Codable, Sendable {
  public var displayID: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(frame: PanelRect, on display: AskGeminiDisplay) {
    displayID = display.id
    x = frame.x - display.frame.x
    y = frame.y - display.frame.y
    width = frame.width
    height = frame.height
  }

  /// The absolute frame on the lock point's display.
  public func frame(on display: AskGeminiDisplay) -> PanelRect {
    PanelRect(
      x: display.frame.x + x,
      y: display.frame.y + y,
      width: width,
      height: height
    )
  }

  var isValid: Bool {
    !displayID.isEmpty && PanelRect(x: x, y: y, width: width, height: height).isUsable
  }
}

/// Machine-wide Gemini panel preferences.
public struct AskGeminiPanelSettings: Equatable, Codable, Sendable {
  /// Browser-style zoom levels; the panel only ever stores one of these.
  public static let zoomSteps: [Double] = [
    0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0,
  ]

  /// The host whose zoom a schema-9 file's single `zoom` value becomes.
  static let legacyZoomHost = "gemini.google.com"

  public var lockPoint: AskGeminiLockPoint?
  /// Zoom per site, like a browser. Absent hosts are 100%.
  public private(set) var zoomByHost: [String: Double]

  public init(
    lockPoint: AskGeminiLockPoint? = nil,
    zoomByHost: [String: Double] = [:]
  ) {
    self.lockPoint = lockPoint
    self.zoomByHost = [:]
    for (host, zoom) in zoomByHost {
      setZoom(zoom, for: host)
    }
  }

  public static let `default` = AskGeminiPanelSettings()

  private enum CodingKeys: String, CodingKey {
    case lockPoint
    case zoomByHost
    /// Schema 9 stored one panel-wide zoom; read only to migrate it.
    case zoom
  }

  /// Drops an unusable lock point, snaps zoom to supported steps, and moves a
  /// schema-9 panel-wide zoom onto Gemini, so a hand-edited or older file
  /// cannot place the panel off screen or at absurd zoom.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lockPoint = try container.decodeIfPresent(
      AskGeminiLockPoint.self,
      forKey: .lockPoint
    )
    var zoomByHost =
      try container.decodeIfPresent([String: Double].self, forKey: .zoomByHost) ?? [:]
    if zoomByHost.isEmpty,
      let legacyZoom = try container.decodeIfPresent(Double.self, forKey: .zoom)
    {
      zoomByHost[Self.legacyZoomHost] = legacyZoom
    }
    self.init(
      lockPoint: lockPoint?.isValid == true ? lockPoint : nil,
      zoomByHost: zoomByHost
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(lockPoint, forKey: .lockPoint)
    try container.encode(zoomByHost, forKey: .zoomByHost)
  }

  /// The saved zoom for a host; pages without a host are 100%.
  public func zoom(for host: String?) -> Double {
    host.flatMap { zoomByHost[Self.normalized($0)] } ?? 1.0
  }

  /// Stores a snapped zoom for a host. 100% removes the entry, as browsers do.
  public mutating func setZoom(_ zoom: Double, for host: String) {
    let host = Self.normalized(host)
    guard !host.isEmpty else {
      return
    }
    let snapped = Self.nearestStep(to: zoom)
    zoomByHost[host] = snapped == 1.0 ? nil : snapped
  }

  /// The next zoom step for a host in one direction, or nil at either end.
  public func steppedZoom(increasing: Bool, for host: String?) -> Double? {
    let zoom = zoom(for: host)
    return increasing
      ? Self.zoomSteps.first { $0 > zoom + 0.001 }
      : Self.zoomSteps.last { $0 < zoom - 0.001 }
  }

  private static func normalized(_ host: String) -> String {
    host.trimmingCharacters(in: .whitespaces).lowercased()
  }

  private static func nearestStep(to zoom: Double) -> Double {
    guard zoom.isFinite else {
      return 1.0
    }
    return zoomSteps.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1.0
  }
}

/// Lock-point state shown by the panel's lock button.
public enum AskGeminiLockState: Equatable, Sendable {
  case unset
  case atLockPoint
  case away
}

/// Pure placement rules for the Gemini panel.
public enum AskGeminiPanelPlacement {
  /// Where the panel opens: the lock point when its display is connected;
  /// otherwise a display other than the active one (preferring the last one
  /// used, at its remembered frame); otherwise the only display.
  public static func openingFrame(
    settings: AskGeminiPanelSettings,
    displays: [AskGeminiDisplay],
    activeDisplayID: String?,
    lastDisplayID: String?,
    rememberedFrames: [String: PanelRect]
  ) -> (displayID: String, frame: PanelRect)? {
    if let lockPoint = settings.lockPoint,
      let display = displays.first(where: { $0.id == lockPoint.displayID })
    {
      return (display.id, lockPoint.frame(on: display))
    }
    let others = displays.filter { $0.id != activeDisplayID }
    let display =
      others.first { $0.id == lastDisplayID }
      ?? others.first
      ?? displays.first { $0.id == activeDisplayID }
      ?? displays.first
    guard let display else {
      return nil
    }
    return (display.id, rememberedFrames[display.id] ?? defaultFrame(on: display))
  }

  /// A tall column at the right edge of the display's usable area.
  public static func defaultFrame(on display: AskGeminiDisplay) -> PanelRect {
    let visible = display.visibleFrame
    let width = max(min(520, visible.width - 40), 1)
    let height = max(visible.height - 40, 1)
    return PanelRect(
      x: visible.maxX - width - 20,
      y: visible.y + 20,
      width: width,
      height: height
    )
  }

  /// The display holding most of a frame, or nil when it is off every display.
  public static func display(
    containing frame: PanelRect,
    in displays: [AskGeminiDisplay]
  ) -> AskGeminiDisplay? {
    let best = displays.max {
      $0.frame.overlapArea(with: frame) < $1.frame.overlapArea(with: frame)
    }
    guard let best, best.frame.overlapArea(with: frame) > 0 else {
      return nil
    }
    return best
  }

  /// Compares with a one-point tolerance because AppKit rounds frames.
  public static func lockState(
    of frame: PanelRect,
    settings: AskGeminiPanelSettings,
    displays: [AskGeminiDisplay]
  ) -> AskGeminiLockState {
    guard let lockPoint = settings.lockPoint else {
      return .unset
    }
    guard let display = displays.first(where: { $0.id == lockPoint.displayID }) else {
      return .away
    }
    return frame.matches(lockPoint.frame(on: display)) ? .atLockPoint : .away
  }
}

/// Browser-style shortcuts the panel handles while it has keyboard focus.
public enum AskGeminiPanelCommand: Equatable, Sendable {
  case newChat
  case closeChat
  /// Closes every chat and hides the panel.
  case closeWindow
  case nextChat
  case previousChat
  case selectChat(Int)
  case lastChat
  case zoomIn
  case zoomOut
  case zoomReset

  /// Maps a key press to a command. Key codes are ANSI positions, so the
  /// shortcuts stay on the same physical keys across layouts.
  public static func command(
    keyCode: UInt16,
    modifiers: Set<KeyModifier>
  ) -> AskGeminiPanelCommand? {
    switch (modifiers, keyCode) {
    case ([.control], KeyCode.tab), ([.command, .shift], KeyCode.rightBracket):
      .nextChat
    case ([.control, .shift], KeyCode.tab), ([.command, .shift], KeyCode.leftBracket):
      .previousChat
    case ([.command], KeyCode.t):
      .newChat
    case ([.command], KeyCode.w):
      .closeChat
    case ([.command, .shift], KeyCode.w):
      .closeWindow
    case ([.command, .shift], KeyCode.equal):
      .zoomIn
    case ([.command, .shift], KeyCode.minus):
      .zoomOut
    case ([.command, .shift], KeyCode.zero):
      .zoomReset
    case ([.command], KeyCode.nine):
      .lastChat
    case ([.command], _):
      KeyCode.digits.firstIndex(of: keyCode).map { .selectChat($0) }
    default:
      nil
    }
  }

  private enum KeyCode {
    static let tab: UInt16 = 48
    static let t: UInt16 = 17
    static let w: UInt16 = 13
    static let rightBracket: UInt16 = 30
    static let leftBracket: UInt16 = 33
    static let equal: UInt16 = 24
    static let minus: UInt16 = 27
    static let zero: UInt16 = 29
    static let nine: UInt16 = 25
    /// Digits 1 through 8, in order.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
  }
}
