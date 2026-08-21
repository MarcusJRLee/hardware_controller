import AppKit

@MainActor
public enum ControllerMenuBarIcon {
  public static func image(active: Bool) -> NSImage {
    let image = NSImage(
      size: NSSize(width: 18, height: 18),
      flipped: false
    ) { rect in
      draw(in: rect, active: active)
      return true
    }
    image.isTemplate = true
    return image
  }

  private static func draw(
    in rect: NSRect,
    active: Bool
  ) {
    let scale = min(
      rect.width / 18,
      rect.height / 18
    )
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current?.cgContext
    context?.translateBy(x: rect.minX, y: rect.minY)
    context?.scaleBy(x: scale, y: scale)

    NSColor.black.setStroke()
    NSColor.black.setFill()

    let signal = NSBezierPath()
    signal.move(to: NSPoint(x: 4.6, y: 9.4))
    signal.curve(
      to: NSPoint(x: 7.3, y: 6.2),
      controlPoint1: NSPoint(x: 5.8, y: 9.4),
      controlPoint2: NSPoint(x: 5.8, y: 6.2)
    )
    signal.line(to: NSPoint(x: 10.7, y: 6.2))
    signal.curve(
      to: NSPoint(x: 13.4, y: 9.4),
      controlPoint1: NSPoint(x: 12.2, y: 6.2),
      controlPoint2: NSPoint(x: 12.2, y: 9.4)
    )
    signal.lineCapStyle = .round
    signal.lineJoinStyle = .round
    signal.lineWidth = 1.4
    signal.stroke()

    let left = NSBezierPath(
      ovalIn: NSRect(x: 1.8, y: 7.5, width: 3.8, height: 3.8)
    )
    let center = NSBezierPath(
      ovalIn: NSRect(x: 6.7, y: 8.4, width: 4.6, height: 4.6)
    )
    let right = NSBezierPath(
      ovalIn: NSRect(x: 12.4, y: 7.5, width: 3.8, height: 3.8)
    )

    left.lineWidth = 1.15
    center.lineWidth = 1.25
    right.lineWidth = 1.15
    left.stroke()
    right.stroke()
    if active {
      center.fill()
    } else {
      center.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
  }
}
