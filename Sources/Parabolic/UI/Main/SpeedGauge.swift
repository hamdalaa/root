import SwiftUI

/// Semicircular speedometer: a glass track, an accent arc that springs to the live value,
/// a glowing knob riding its tip and a big rounded readout in the middle.
struct SpeedGauge: View {
    /// Megabits per second shown by the arc.
    var mbps: Double
    /// Big centre number and its unit ("245" / "Mbps").
    var readout: String
    var unit: String
    var caption: String
    var tint: Color
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let diameter: CGFloat = 300
    private static let lineWidth: CGFloat = 18
    /// Speedtest-style scale: equal spacing between marks, so slow and fast lines both read well.
    static let marks: [Double] = [0, 5, 10, 25, 50, 100, 250, 500, 1000]

    /// Position (0…1) of a value on the non-linear scale.
    static func fraction(for mbps: Double) -> Double {
        let value = min(max(mbps, 0), marks.last!)
        guard let upper = marks.firstIndex(where: { $0 >= value }), upper > 0 else { return 0 }
        let lo = marks[upper - 1], hi = marks[upper]
        let local = (value - lo) / (hi - lo)
        return (Double(upper - 1) + local) / Double(marks.count - 1)
    }

    private var fraction: Double { Self.fraction(for: mbps) }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.7, dampingFraction: 0.78)
    }

    var body: some View {
        let d = Self.diameter
        ZStack(alignment: .top) {
            // Track
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(.primary.opacity(0.08), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(180))
                .frame(width: d, height: d)

            // Fill
            Circle()
                .trim(from: 0, to: 0.5 * max(fraction, 0.0001))
                .stroke(AngularGradient(colors: [tint.opacity(0.35), tint.opacity(0.85), tint],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(180)),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(180))
                .frame(width: d, height: d)
                .shadow(color: tint.opacity(isActive ? 0.45 : 0.15), radius: isActive ? 10 : 4)
                .opacity(fraction > 0 ? 1 : 0)

            ticks.frame(width: d, height: d)
            knob.frame(width: d, height: d)

            centre
                .frame(width: d)
                .padding(.top, d * 0.2)
        }
        .frame(width: d + Self.lineWidth, height: d / 2 + Self.lineWidth / 2 + 18, alignment: .top)
        .padding(.top, Self.lineWidth / 2)
        .animation(motion, value: fraction)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue("\(readout) \(unit)")
    }

    /// Scale labels just inside the arc.
    private var ticks: some View {
        let radius = Self.diameter / 2 - Self.lineWidth - 14
        return ZStack {
            ForEach(Array(Self.marks.enumerated()), id: \.offset) { index, mark in
                let angle = Angle.degrees(180 + 180 * Double(index) / Double(Self.marks.count - 1))
                let lit = fraction >= Double(index) / Double(Self.marks.count - 1) - 0.0001 && fraction > 0
                Text(mark >= 1000 ? "1k" : mark.formatted())
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(lit ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
            }
        }
    }

    /// A small white disc on the tip of the arc, rotated with the value so it tracks the fill exactly.
    private var knob: some View {
        ZStack(alignment: .leading) {
            Color.clear
            Circle()
                .fill(.white)
                .frame(width: Self.lineWidth - 6, height: Self.lineWidth - 6)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                // Centred on the arc's path (the circle's edge), where the stroke is centred too.
                .offset(x: -(Self.lineWidth - 6) / 2)
                .opacity(fraction > 0 ? 1 : 0)
        }
        .rotationEffect(.degrees(180 * fraction))
    }

    private var centre: some View {
        VStack(spacing: 0) {
            Text(readout)
                .font(.system(size: 60, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: mbps))
                .foregroundStyle(readout == "—" || mbps <= 0 && !isActive ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : .snappy, value: readout)
    }
}
