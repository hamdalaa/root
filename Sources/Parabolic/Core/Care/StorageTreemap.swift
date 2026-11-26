import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk): each value gets a rectangle whose area is proportional
/// to its share of the total, with aspect ratios kept close to 1 so small blocks stay legible.
enum StorageTreemap {
    /// Returns one rect per value, in the same order as `values`. Zero or negative values get a zero-size rect.
    static func layout(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect(origin: bounds.origin, size: .zero), count: values.count)
        let order = values.indices.filter { values[$0] > 0 && values[$0].isFinite }
            .sorted { values[$0] > values[$1] }
        let total = order.reduce(0) { $0 + values[$1] }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }

        let scale = Double(bounds.width * bounds.height) / total
        let areas = order.map { values[$0] * scale }
        var remaining = bounds
        var row: [Int] = []
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [index], areas, side) <= worst(row, areas, side) {
                row.append(index)
                index += 1
            } else {
                remaining = place(row, areas, order, in: remaining, isLast: false, into: &result)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { _ = place(row, areas, order, in: remaining, isLast: true, into: &result) }
        return result
    }

    /// Worst aspect ratio in a row laid along a side of length `side`.
    private static func worst(_ row: [Int], _ areas: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0) { $0 + areas[$1] }
        guard sum > 0, side > 0 else { return .infinity }
        let largest = row.map { areas[$0] }.max() ?? 0
        let smallest = row.map { areas[$0] }.min() ?? 0
        let side2 = side * side, sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * max(smallest, .leastNonzeroMagnitude)))
    }

    /// Lays a row along the shorter side of `rect` and returns what's left.
    private static func place(_ row: [Int], _ areas: [Double], _ order: [Int], in rect: CGRect,
                              isLast: Bool, into result: inout [CGRect]) -> CGRect {
        let sum = row.reduce(0) { $0 + areas[$1] }
        if rect.width >= rect.height {
            // Column on the left.
            let width = isLast ? rect.width : min(rect.width, CGFloat(sum / Double(rect.height)))
            var y = rect.minY
            for (position, item) in row.enumerated() {
                let height = position == row.count - 1 ? rect.maxY - y : CGFloat(areas[item] / Double(width))
                result[order[item]] = CGRect(x: rect.minX, y: y, width: width, height: max(0, height))
                y += height
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            // Row along the top.
            let height = isLast ? rect.height : min(rect.height, CGFloat(sum / Double(rect.width)))
            var x = rect.minX
            for (position, item) in row.enumerated() {
                let width = position == row.count - 1 ? rect.maxX - x : CGFloat(areas[item] / Double(height))
                result[order[item]] = CGRect(x: x, y: rect.minY, width: max(0, width), height: height)
                x += width
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}
