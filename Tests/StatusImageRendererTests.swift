import AppKit
import SwiftUI
import Testing

@MainActor @Suite struct StatusImageRendererTests {
    private var label: some View {
        HStack(spacing: 2) {
            Image(systemName: "asterisk").frame(width: 14, height: 14)
            Text("1d12h").font(.system(size: 8, weight: .semibold).monospacedDigit())
        }.fixedSize()
    }

    @Test func retinaBitmapsPreserveLogicalSize() throws {
        let image = try #require(StatusImageRenderer.image(label, preferredScale: 1))
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(bitmaps.count == 2)
        #expect(bitmaps.allSatisfy { $0.size == image.size })
        #expect(bitmaps.map(\.pixelsWide) == [Int(image.size.width), Int(image.size.width * 2)])
        #expect(bitmaps.map(\.pixelsHigh) == [Int(image.size.height), Int(image.size.height * 2)])
        let retina = try #require(bitmaps.last)
        let context = try #require(NSGraphicsContext(bitmapImageRep: retina))
        context.cgContext.scaleBy(x: 2, y: 2)
        let selected = try #require(image.bestRepresentation(for: NSRect(origin: .zero, size: image.size),
                                                            context: context, hints: nil))
        #expect(selected.pixelsWide == Int(image.size.width * 2))
    }

    @Test func higherDensityKeepsMenuBarPointSize() throws {
        let regular = try #require(StatusImageRenderer.image(label, preferredScale: 1))
        let dense = try #require(StatusImageRenderer.image(label, preferredScale: 3))
        #expect(dense.size == regular.size)
        #expect(dense.representations.map(\.pixelsWide) == [1, 2, 3].map { Int(dense.size.width) * $0 })
    }
}
