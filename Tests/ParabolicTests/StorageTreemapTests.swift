import CoreGraphics
import Testing
@testable import Parabolic

@Suite struct StorageTreemapTests {
    private let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)

    @Test(arguments: [
        [6.0, 6, 4, 3, 2, 2, 1],
        [100.0],
        [1.0, 1, 1, 1],
        [500.0, 3, 2, 1, 0.5],
        [7.0, 13, 2, 41, 5, 3, 3, 8, 1, 21],
    ])
    func areasAreProportionalAndInsideBounds(values: [Double]) {
        let rects = StorageTreemap.layout(values, in: bounds)
        #expect(rects.count == values.count)
        let total = values.reduce(0, +)
        let area = Double(bounds.width * bounds.height)
        for (value, rect) in zip(values, rects) {
            let expected = value / total * area
            #expect(abs(Double(rect.width * rect.height) - expected) < max(1, expected * 0.001))
            #expect(rect.minX >= bounds.minX - 0.001 && rect.maxX <= bounds.maxX + 0.001)
            #expect(rect.minY >= bounds.minY - 0.001 && rect.maxY <= bounds.maxY + 0.001)
        }
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - area) < 1)
    }

    @Test func rectsDoNotOverlap() {
        let values: [Double] = [40, 30, 12, 9, 5, 2, 1, 1]
        let rects = StorageTreemap.layout(values, in: bounds)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].insetBy(dx: 0.01, dy: 0.01).intersection(rects[j].insetBy(dx: 0.01, dy: 0.01))
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func keepsInputOrderAndIgnoresZeros() {
        let rects = StorageTreemap.layout([1, 0, 9, -3], in: bounds)
        #expect(rects[1].width * rects[1].height == 0)
        #expect(rects[3].width * rects[3].height == 0)
        #expect(rects[2].width * rects[2].height > rects[0].width * rects[0].height * 8)
    }

    @Test func squarifiedAspectRatiosStayReasonable() {
        let rects = StorageTreemap.layout([1, 1, 1, 1], in: CGRect(x: 0, y: 0, width: 200, height: 200))
        for rect in rects {
            #expect(max(rect.width / rect.height, rect.height / rect.width) <= 1.01)
        }
    }

    @Test func degenerateInputsReturnEmptyRects() {
        #expect(StorageTreemap.layout([], in: bounds).isEmpty)
        #expect(StorageTreemap.layout([0, 0], in: bounds).allSatisfy { $0.width * $0.height == 0 })
        #expect(StorageTreemap.layout([3, 2], in: .zero).allSatisfy { $0.width * $0.height == 0 })
    }
}
