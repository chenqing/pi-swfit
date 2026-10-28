#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

// Deterministic export of our two-fill SVG master. No raster retouching or font dependency.
let input = CommandLine.arguments.dropFirst().first ?? "Brand/PiSwift.svg"
let output = CommandLine.arguments.dropFirst(2).first ?? "Examples/PiSwift/Assets/AppIcon.png"
let source = try String(contentsOfFile: input, encoding: .utf8)
func attribute(_ name: String, in element: String) -> String {
    let regex = try! NSRegularExpression(pattern: "\\b" + name + "=\"([^\"]+)\"")
    let match = regex.firstMatch(in: element, range: NSRange(element.startIndex..., in: element))!
    return String(element[Range(match.range(at: 1), in: element)!])
}
func element(_ name: String) -> String {
    let regex = try! NSRegularExpression(pattern: "<" + name + "\\b[^>]+>")
    let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
    return String(source[Range(match.range, in: source)!])
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: String) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(colorSpace: space, components: [CGFloat((value >> 16) & 255) / 255,
        CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255, 1])!
}
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
let tile = element("rect")
func number(_ name: String) -> CGFloat { CGFloat(Double(attribute(name, in: tile))!) }
context.addPath(CGPath(roundedRect: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                      cornerWidth: number("rx"), cornerHeight: number("rx"), transform: nil))
context.setFillColor(color(attribute("fill", in: tile))); context.fillPath()
let glyph = element("path"), data = attribute("d", in: glyph)
let regex = try NSRegularExpression(pattern: "[MLCQZ]|-?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)")
let tokens = regex.matches(in: data, range: NSRange(data.startIndex..., in: data)).map { String(data[Range($0.range, in: data)!]) }
var index = 0
func point() -> CGPoint {
    defer { index += 2 }
    return CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
}
let path = CGMutablePath()
while index < tokens.count {
    let command = tokens[index]; index += 1
    switch command {
    case "M": path.move(to: point())
    case "L": path.addLine(to: point())
    case "C": let a = point(), b = point(), end = point(); path.addCurve(to: end, control1: a, control2: b)
    case "Q": let control = point(), end = point(); path.addQuadCurve(to: end, control: control)
    case "Z": path.closeSubpath()
    default: fatalError("Unsupported path command: \(command)")
    }
}
context.addPath(path); context.setFillColor(color(attribute("fill", in: glyph))); context.fillPath()
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
print(output)
