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
    /// Sites with no icon on disk, so asking again costs no disk read.
    private var notOnDisk: Set<String> = []
    /// The icon URL each site last declared. A page declares its icon on every
    /// load; only a *new* declaration is worth a request.
    private var declaredFor: [String: URL] = [:]
    private var inFlight: [String: Task<Fetched?, Never>] = [:]
    private let directory: URL
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.networkServiceType = .background
        return URLSession(configuration: configuration)
    }()

    private init() {
        directory = JSONFile<Int>.defaultDirectory.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cached icon, if any, without fetching.
    func cached(for url: URL?) -> NSImage? {
        guard let key = SiteKey.for(url) else { return nil }
        if let image = memory[key] { return image }
        if notOnDisk.contains(key) { return nil }
        let file = directory.appendingPathComponent(key + ".png")
        if let image = NSImage(contentsOf: file) {
            memory[key] = image
            return image
        }
        notOnDisk.insert(key)
        return nil
    }

    /// Fetch an icon for `pageURL`, preferring what the page declared.
    ///
    /// `persist: false` (a private window) fetches without remembering: the
    /// icon is neither written to disk nor shared with other windows.
    func icon(for pageURL: URL, declared: URL?, persist: Bool = true) async -> NSImage? {
        guard let key = SiteKey.for(pageURL) else { return nil }
        let isNewDeclaration = declared != nil && declaredFor[key] != declared
        if let image = cached(for: pageURL), !isNewDeclaration { return image }
        if !persist { return await Self.fetchFirst(Self.candidates(for: pageURL, declared: declared))?.image }
        if let task = inFlight[key] { return await task.value?.image }
        if failed.contains(key), !isNewDeclaration { return nil }
        if let declared { declaredFor[key] = declared }

        let candidates = Self.candidates(for: pageURL, declared: declared)
        let file = directory.appendingPathComponent(key + ".png")
        let task = Task<Fetched?, Never> {
            let fetched = await Self.fetchFirst(candidates)
            // Already PNG; written off the main thread.
            try? fetched?.png.write(to: file, options: .atomic)
            return fetched
        }
        inFlight[key] = task
        let fetched = await task.value
        inFlight[key] = nil

        guard let image = fetched?.image else {
            failed.insert(key)
            return cached(for: pageURL)
        }
        memory[key] = image
        return image
    }

    private static func candidates(for pageURL: URL, declared: URL?) -> [URL] {
        var candidates: [URL] = []
        if let declared, declared.scheme == "https" || declared.scheme == "http" || declared.scheme == "data" {
            candidates.append(declared)
        }
        if let host = pageURL.host(), let fallback = URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico") {
            candidates.append(fallback)
        }
        return candidates
    }

    private nonisolated static func fetchFirst(_ candidates: [URL]) async -> Fetched? {
        for candidate in candidates {
            if let fetched = await fetch(candidate, session: session) { return fetched }
        }
        return nil
    }

    private struct Fetched: @unchecked Sendable {
        let image: NSImage
        let png: Data
    }

    /// Fetch and rasterise at 64px: `.ico` files hold several sizes and NSImage
    /// picks a soft 16px one when drawing small on Retina.
    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> Fetched? {
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
        guard let result = NSImage(data: png) else { return nil }
        result.size = NSSize(width: 32, height: 32)
        return Fetched(image: result, png: png)
    }
}
