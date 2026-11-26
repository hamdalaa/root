import SwiftUI

extension Platform {
    /// Brand colour; monochrome brands follow the primary label colour so they work in light and dark.
    var brandColor: Color {
        guard let hex = brandHex else { return .primary }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Parsed, cached 24×24 path.
    var glyph: Path? {
        PlatformGlyphCache.shared.path(for: self)
    }
}

/// A platform's brand mark. Falls back to a globe for unknown sites.
/// `style: .brand` uses the brand colour; `.monochrome` uses the current foreground style.
struct PlatformGlyph: View {
    enum Style { case brand, monochrome }

    var platform: Platform
    var size: CGFloat = 16
    var style: Style = .brand

    var body: some View {
        Group {
            if let path = platform.glyph {
                GlyphShape(path: path)
                    .fill(style == .brand ? AnyShapeStyle(platform.brandColor) : AnyShapeStyle(.foreground))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(style == .brand ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(platform.title)
    }
}

/// Platform mark inside a small glass tile — used in the sidebar, rows and the URL field.
struct PlatformBadge: View {
    var platform: Platform
    var size: CGFloat = 22

    var body: some View {
        PlatformGlyph(platform: platform, size: size * 0.6)
            .frame(width: size, height: size)
            .background(.background.opacity(0.75), in: .rect(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct GlyphShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

private final class PlatformGlyphCache: @unchecked Sendable {
    static let shared = PlatformGlyphCache()
    private var cache: [Platform: Path] = [:]
    private let lock = NSLock()

    func path(for platform: Platform) -> Path? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[platform] { return hit }
        guard let data = platform.glyphPath else { return nil }
        let parsed = SVGPathParser.parse(data)
        cache[platform] = parsed
        return parsed
    }
}

/// Minimal SVG path-data parser (all commands incl. arcs, relative + absolute, compact flags).
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var scanner = Tokenizer(Array(d.utf8))
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next { command = c } else if command == 0 { break }
            let relative = command >= 97
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch command | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p); current = p; start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // implicit lineto
                lastControl = nil
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case UInt8(ascii: "s"):
                let wasCubic = [UInt8(ascii: "c"), UInt8(ascii: "s")].contains(lastCommand | 0x20)
                let c1 = wasCubic ? reflect(lastControl, around: current) : current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case UInt8(ascii: "t"):
                let wasQuad = [UInt8(ascii: "q"), UInt8(ascii: "t")].contains(lastCommand | 0x20)
                let c = wasQuad ? reflect(lastControl, around: current) : current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep)
                current = p; lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ point: CGPoint?, around center: CGPoint) -> CGPoint {
        guard let point else { return center }
        return CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Endpoint → centre parameterisation (SVG spec F.6.5), then cubic approximation per ≤90° segment.
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        func pointAt(_ t: CGFloat) -> (CGPoint, CGPoint) {
            let x = rx * cos(t), y = ry * sin(t)
            let dxT = -rx * sin(t), dyT = ry * cos(t)
            let pt = CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
            let tangent = CGPoint(x: cosPhi * dxT - sinPhi * dyT, y: sinPhi * dxT + cosPhi * dyT)
            return (pt, tangent)
        }
        for _ in 0..<segments {
            let (a, ta) = pointAt(theta)
            let (b, tb) = pointAt(theta + step)
            path.addCurve(to: b,
                          control1: CGPoint(x: a.x + k * ta.x, y: a.y + k * ta.y),
                          control2: CGPoint(x: b.x - k * tb.x, y: b.y - k * tb.y))
            theta += step
        }
    }

    private struct Tokenizer {
        enum Token { case command(UInt8), number }
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || bytes[index] == 10 || bytes[index] == 9 || bytes[index] == 13 { index += 1 }
        }

        /// Returns a command letter (consuming it) or `.number` when a number follows (not consumed).
        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122), b != UInt8(ascii: "e"), b != UInt8(ascii: "E") {
                index += 1
                return .command(b)
            }
            return .number
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            guard b == UInt8(ascii: "0") || b == UInt8(ascii: "1") else { return nil }
            index += 1
            return b == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let startIndex = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var sawDot = false, sawDigit = false
            while index < bytes.count {
                let b = bytes[index]
                if b >= 48 && b <= 57 { sawDigit = true; index += 1 }
                else if b == 46, !sawDot { sawDot = true; index += 1 }
                else if (b == 101 || b == 69), sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
                } else { break }
            }
            guard sawDigit, let text = String(bytes: bytes[startIndex..<index], encoding: .ascii), let value = Double(text) else {
                index = startIndex
                return nil
            }
            return CGFloat(value)
        }
    }
}
