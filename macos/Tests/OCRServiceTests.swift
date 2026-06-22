import CoreGraphics
import Testing
@testable import Translator_Everywhere

/// A synthetic `ReadingOrderItem` — real `VNRecognizedTextObservation`s cannot
/// be constructed by hand, so we test the reading-order sort against a value
/// type carrying the same `boundingBox` contract (Vision-normalized, y-up).
private struct FakeItem: ReadingOrderItem {
    let label: String
    let boundingBox: CGRect

    /// Convenience: place an item by its row/column in *visual* terms — `y` is
    /// the visual top fraction (0 = top of image), translated to Vision's y-up.
    init(_ label: String, visualTop: CGFloat, left: CGFloat, width: CGFloat = 0.1, height: CGFloat = 0.05) {
        self.label = label
        // Vision y grows upward, so visualTop 0.1 → origin.y = 1 - 0.1 - height.
        let originY = 1.0 - visualTop - height
        self.boundingBox = CGRect(x: left, y: originY, width: width, height: height)
    }
}

@Suite("OCRService reading-order sort")
struct OCRServiceTests {

    @Test("Orders top→bottom then left→right")
    func ordersTopToBottomThenLeftToRight() {
        // Deliberately scrambled input.
        let items = [
            FakeItem("bottom-right", visualTop: 0.80, left: 0.60),
            FakeItem("top-right", visualTop: 0.10, left: 0.60),
            FakeItem("top-left", visualTop: 0.10, left: 0.10),
            FakeItem("bottom-left", visualTop: 0.80, left: 0.10),
        ]

        let ordered = OCRService.sortedReadingOrder(items).map(\.label)

        #expect(ordered == ["top-left", "top-right", "bottom-left", "bottom-right"])
    }

    @Test("Items on the same visual row are ordered left→right despite y jitter")
    func sameRowSortsByX() {
        // Same row, tiny y jitter under the same-line tolerance; columns out of order.
        let items = [
            FakeItem("c", visualTop: 0.302, left: 0.70),
            FakeItem("a", visualTop: 0.300, left: 0.10),
            FakeItem("b", visualTop: 0.301, left: 0.40),
        ]

        let ordered = OCRService.sortedReadingOrder(items).map(\.label)

        #expect(ordered == ["a", "b", "c"])
    }

    @Test("Empty input yields empty output")
    func emptyInput() {
        let ordered = OCRService.sortedReadingOrder([FakeItem]())
        #expect(ordered.isEmpty)
    }
}
