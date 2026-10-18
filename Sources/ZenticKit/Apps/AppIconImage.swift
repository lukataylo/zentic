import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turning whatever the image model sent into a small, plain PNG.
///
/// Decoded and re-encoded rather than stored as received: the bytes came off
/// the network, and what is kept — and later shown in the sidebar — should be a
/// bitmap Zentic drew itself, at a size that suits a tile.
public enum AppIconImage {
    public static func thumbnail(_ data: Data, pixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
