import CoreGraphics

/// Where a new popup goes: the top-right corner, under the popups already showing (like notifications).
/// A full column starts a new one to its left; a slot freed by a closed popup is reused.
enum CatchPanelLayout {
    static let margin: CGFloat = 16
    static let gap: CGFloat = 10

    static func origin(for size: CGSize, occupied: [CGRect], in visible: CGRect) -> CGPoint {
        var right = visible.maxX - margin
        while right - size.width >= visible.minX {
            var top = visible.maxY - margin
            while top - size.height >= visible.minY + margin {
                let slot = CGRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height)
                guard let blocker = occupied.filter({ $0.intersects(slot.insetBy(dx: 1, dy: 1)) }).min(by: { $0.minY < $1.minY }) else {
                    return slot.origin
                }
                top = blocker.minY - gap
            }
            right -= size.width + gap
        }
        // No free slot: cascade over the first one.
        let offset = CGFloat(occupied.count % 8) * 24
        return CGPoint(x: visible.maxX - margin - size.width - offset, y: visible.maxY - margin - size.height - offset)
    }
}
