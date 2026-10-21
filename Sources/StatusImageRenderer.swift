import SwiftUI
import AppKit

/// Keep logical point size independent from pixel size, with a native bitmap for each display density.
@MainActor enum StatusImageRenderer {
    static func image<Content: View>(_ content: Content, preferredScale: CGFloat) -> NSImage? {
        let measurement = ImageRenderer(content: content)
        var size = NSSize.zero
        measurement.render { measured, _ in
            size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size)
        // Include Retina even when first rendered on a non-Retina display, so AppKit can select it
        // immediately when the menu bar is mirrored or moved before a screen notification arrives.
        for scale in Set([CGFloat(1), CGFloat(2), max(1, preferredScale)]).sorted() {
            let renderer = ImageRenderer(content: content
                .frame(width: size.width, height: size.height, alignment: .leading)
                .environment(\.displayScale, scale))
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { return nil }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            representation.size = size
            image.addRepresentation(representation)
        }
        return image
    }
}

/// Caches rendered menu-bar frames so the animation is a cheap image swap.
@MainActor final class LabelCache {
    static let shared = LabelCache()
    private var base = ""
    private var frames: [Int: NSImage] = [:]
    func image(base: String, frame: Int, render: () -> NSImage) -> NSImage {
        if base != self.base { self.base = base; frames.removeAll() }
        if let img = frames[frame] { return img }
        let img = render()
        frames[frame] = img
        return img
    }
}

