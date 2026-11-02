// Renders both app icons from code so the art is reproducible and reviewable.
// Run from the repository root: swift tools/app_icons/render_app_icons.swift
//
// One family: a graphite tile, rounded capsules, and amber for the center
// element, matching the apps' rule that amber marks the active thing.
// Hardware Controller shows three pedals from above with the center pedal lit;
// Voice Input shows a five-bar voice waveform with the center bar lit.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1_024

struct RGB {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat

  init(_ hex: UInt32) {
    red = CGFloat((hex >> 16) & 0xff) / 255
    green = CGFloat((hex >> 8) & 0xff) / 255
    blue = CGFloat(hex & 0xff) / 255
  }

  func color(alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }
}

let graphiteTop = RGB(0x3A3D44)
let graphiteBottom = RGB(0x15161A)
let amberTop = RGB(0xFFD15C)
let amberBottom = RGB(0xF39A12)
let chalkTop = RGB(0xF7F7F5)
let chalkBottom = RGB(0xC4C6CB)

func makeContext() -> CGContext {
  guard
    let context = CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    fatalError("Could not create a bitmap context.")
  }
  // Draw in top-left coordinates like the design grid.
  context.translateBy(x: 0, y: CGFloat(size))
  context.scaleBy(x: 1, y: -1)
  return context
}

func linearGradient(_ top: RGB, _ bottom: RGB) -> CGGradient {
  guard
    let gradient = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
      colors: [top.color(), bottom.color()] as CFArray,
      locations: [0, 1]
    )
  else {
    fatalError("Could not create a gradient.")
  }
  return gradient
}

/// A continuous-corner rounded square (superellipse), like Apple's icon shape.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
  let path = CGMutablePath()
  let steps = 720
  for step in 0...steps {
    let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
    let cosine = cos(angle)
    let sine = sin(angle)
    let x = pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1)
    let y = pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1)
    let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
    step == 0 ? path.move(to: point) : path.addLine(to: point)
  }
  path.closeSubpath()
  return path
}

func fill(_ path: CGPath, in context: CGContext, top: RGB, bottom: RGB) {
  let box = path.boundingBox
  context.saveGState()
  context.addPath(path)
  context.clip()
  context.drawLinearGradient(
    linearGradient(top, bottom),
    start: CGPoint(x: box.midX, y: box.minY),
    end: CGPoint(x: box.midX, y: box.maxY),
    options: []
  )
  context.restoreGState()
}

/// The graphite surface with a faint top sheen.
func drawTile(_ path: CGPath, in context: CGContext) {
  fill(path, in: context, top: graphiteTop, bottom: graphiteBottom)
  let box = path.boundingBox
  context.saveGState()
  context.addPath(path)
  context.clip()
  guard
    let sheen = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
      colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
      locations: [0, 1]
    )
  else {
    fatalError("Could not create the sheen.")
  }
  context.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: box.midX, y: box.minY),
    startRadius: 0,
    endCenter: CGPoint(x: box.midX, y: box.minY),
    endRadius: box.height * 0.75,
    options: []
  )
  context.restoreGState()
}

/// A capsule with a soft cast shadow, a vertical gradient, and an optional
/// inner glow for the lit element.
func drawCapsule(
  _ rect: CGRect,
  in context: CGContext,
  top: RGB,
  bottom: RGB,
  glow: RGB? = nil,
  treads: Int = 0
) {
  let radius = rect.width / 2
  let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  context.saveGState()
  if let glow {
    context.setShadow(offset: .zero, blur: 70, color: glow.color(alpha: 0.55))
  } else {
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: CGColor(gray: 0, alpha: 0.55))
  }
  context.addPath(path)
  context.setFillColor(bottom.color())
  context.fillPath()
  context.restoreGState()
  fill(path, in: context, top: top, bottom: bottom)

  // Pedal treads: short recessed bars across the upper face.
  guard treads > 0 else {
    return
  }
  let treadWidth = rect.width * 0.46
  let treadHeight = rect.width * 0.075
  let spacing = treadHeight * 2.6
  let firstY = rect.minY + rect.width * 0.62
  context.saveGState()
  context.setFillColor(CGColor(gray: 0, alpha: 0.16))
  for index in 0..<treads {
    let tread = CGRect(
      x: rect.midX - treadWidth / 2,
      y: firstY + CGFloat(index) * spacing,
      width: treadWidth,
      height: treadHeight
    )
    context.addPath(
      CGPath(
        roundedRect: tread,
        cornerWidth: treadHeight / 2,
        cornerHeight: treadHeight / 2,
        transform: nil
      ))
    context.fillPath()
  }
  context.restoreGState()
}

func centered(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
  CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
}

func write(_ context: CGContext, to path: String) {
  guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: path) as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    fatalError("Could not encode \(path).")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not write \(path).")
  }
  print(path)
}

/// macOS draws its own tile on Apple's 824-point grid with a drop shadow.
func renderMac() {
  let context = makeContext()
  let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tile = squircle(in: tileRect)
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
  context.addPath(tile)
  context.setFillColor(graphiteBottom.color())
  context.fillPath()
  context.restoreGState()
  drawTile(tile, in: context)

  let sideWidth: CGFloat = 132
  let sideHeight: CGFloat = 384
  let centerWidth: CGFloat = 176
  let centerHeight: CGFloat = 492
  drawCapsule(
    centered(x: 512 - 222, y: 548, width: sideWidth, height: sideHeight),
    in: context, top: chalkTop, bottom: chalkBottom, treads: 3)
  drawCapsule(
    centered(x: 512 + 222, y: 548, width: sideWidth, height: sideHeight),
    in: context, top: chalkTop, bottom: chalkBottom, treads: 3)
  drawCapsule(
    centered(x: 512, y: 518, width: centerWidth, height: centerHeight),
    in: context, top: amberTop, bottom: amberBottom, glow: amberBottom, treads: 4)
  write(context, to: "packaging/app_icon_source.png")
}

/// iOS masks the icon itself, so the tile fills the whole square.
func renderIOS() {
  let context = makeContext()
  drawTile(CGPath(rect: CGRect(x: 0, y: 0, width: size, height: size), transform: nil), in: context)
  let barWidth: CGFloat = 96
  let pitch: CGFloat = 150
  let heights: [CGFloat] = [280, 476, 660, 476, 280]
  for (index, height) in heights.enumerated() {
    let rect = centered(
      x: 512 + CGFloat(index - 2) * pitch, y: 512, width: barWidth, height: height)
    if index == 2 {
      drawCapsule(rect, in: context, top: amberTop, bottom: amberBottom, glow: amberBottom)
    } else {
      drawCapsule(rect, in: context, top: chalkTop, bottom: chalkBottom)
    }
  }
  write(context, to: "apps/ios/voice_input/resources/assets.xcassets/AppIcon.appiconset/app_icon.png")
}

renderMac()
renderIOS()
