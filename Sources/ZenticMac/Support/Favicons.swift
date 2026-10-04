import AppKit
import Foundation
import ZenticKit

/// Site icons, per site key, cached in memory and on disk.
///
/// Per-site rather than per-page: an icon is a property of a site, so one fetch
/// serves every tab on it, and a tab restored at launch has its icon on the very
/// first frame, before any network.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private var memory: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    private init() {
        directory = JSONFile<Int>.defaultDirectory.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.networkServiceType = .background
        session = URLSession(configuration: configuration)
    }

    /// The cached icon, if any, without fetching.
    func cached(for url: URL?) -> NSImage? {
        guard let key = SiteKey.for(url) else { return nil }
        if let image = memory[key] { return image }
        let file = directory.appendingPathComponent(key + ".png")
        if let image = NSImage(contentsOf: file) {
            memory[key] = image
            return image
        }
        return nil
    }

    /// Fetch an icon for `pageURL`, preferring what the page declared.
    func icon(for pageURL: URL, declared: URL?) async -> NSImage? {
        guard let key = SiteKey.for(pageURL) else { return nil }
        if let image = cached(for: pageURL), declared == nil { return image }
        if let task = inFlight[key] { return await task.value }
        if failed.contains(key), declared == nil { return nil }

        var candidates: [URL] = []
        if let declared, declared.scheme == "https" || declared.scheme == "http" || declared.scheme == "data" {
            candidates.append(declared)
        }
        if let host = pageURL.host(), let fallback = URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico") {
            candidates.append(fallback)
        }

        let session = self.session
        let task = Task<NSImage?, Never> {
            for candidate in candidates {
                if let image = await Self.fetch(candidate, session: session) { return image }
            }
            return nil
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        guard let image else {
            failed.insert(key)
            return cached(for: pageURL)
        }
        memory[key] = image
        if let png = image.pngData() {
            try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
        }
        return image
    }

    /// Fetch and rasterise at 64px: `.ico` files hold several sizes and NSImage
    /// picks a soft 16px one when drawing small on Retina.
    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        let data: Data
        if url.scheme == "data" {
            guard let d = try? Data(contentsOf: url) else { return nil }
            data = d
        } else {
            guard let (d, response) = try? await session.data(from: url),
                let http = response as? HTTPURLResponse, http.statusCode == 200, !d.isEmpty
            else { return nil }
            data = d
        }
        guard let source = NSImage(data: data), source.size.width > 0 else { return nil }
        let side: CGFloat = 64
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let result = NSImage(data: png)
        result?.size = NSSize(width: 32, height: 32)
        return result
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
