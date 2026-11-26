// Renders the Root app icon from assets/AppIcon-source.png (Root inside the Machine's
// surveillance box): the picture fills Apple's continuous-corner squircle on the macOS 26
// icon grid, with the standard drop shadow and a faint rim.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../assets/AppIcon-source.png").standardizedFileURL

func white(_ alpha: CGFloat) -> CGColor { CGColor(gray: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(gray: 0, alpha: alpha) }

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let picture = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Couldn't read \(source.path)")
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824) // macOS 26 icon grid
let bodyPath = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body).cgPath

let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// Drop shadow beneath the squircle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: black(0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(black(1))
ctx.fillPath()
ctx.restoreGState()

// The picture, aspect-filled into the squircle.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let scale = max(body.width / CGFloat(picture.width), body.height / CGFloat(picture.height))
let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
ctx.draw(picture, in: CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                             width: size.width, height: size.height))
ctx.restoreGState()

// Faint rim so the edge reads on dark Docks.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.addPath(bodyPath)
ctx.setLineWidth(4)
ctx.setStrokeColor(white(0.18))
ctx.strokePath()
ctx.restoreGState()

guard let cgImage = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Couldn't render the icon")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output)") }
