import AppKit
import Foundation

/// Fetches and caches site icons.
///
/// Per-host, not per-page: a favicon is a property of a site, so one fetch serves
/// every tab on it and a suspended tab keeps its icon in the sidebar for free.
/// Results are also written to the tab record, so the sidebar is populated on the
/// very first frame after a relaunch, before any network happens.
@MainActor
final class FaviconService {
    private var cache: [String: Data] = [:]
    /// Hosts whose icon fetch failed, so a site with no icon is not re-fetched on
    /// every navigation.
    private var failed: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 6
        // Favicon fetches must never be the reason a page feels slow.
        configuration.networkServiceType = .background
        session = URLSession(configuration: configuration)
    }

    func iconData(pageURL: URL, declared: URL?) async -> Data? {
        guard let host = pageURL.host() else { return nil }
        if let cached = cache[host] { return cached }
        if failed.contains(host) { return nil }
        if let existing = inFlight[host] { return await existing.value }

        // The page's own declaration first, then the well-known path. Cross-host
        // declarations are dropped: a page must not be able to make us fetch from
        // an arbitrary third party.
        var candidates: [URL] = []
        if let declared, declared.host() == host { candidates.append(declared) }
        if let fallback = URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico") {
            candidates.append(fallback)
        }

        let task = Task<Data?, Never> { [session] in
            for candidate in candidates {
                if let data = await Self.fetch(candidate, using: session) { return data }
            }
            return nil
        }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil

        if let result {
            cache[host] = result
        } else {
            failed.insert(host)
        }
        return result
    }

    /// Fetch and re-encode to PNG.
    ///
    /// Re-encoding is deliberate: `.ico` files routinely hold several sizes, and
    /// `NSImage` picks a 16pt representation when asked to draw small, which looks
    /// soft on Retina. Rasterising once at 32pt gives a crisp tile everywhere.
    @MainActor
    private static func fetch(_ url: URL, using session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            !data.isEmpty,
            let image = NSImage(data: data)
        else { return nil }

        let side: CGFloat = 32
        let scaled = NSImage(size: NSSize(width: side, height: side))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        scaled.unlockFocus()

        guard let tiff = scaled.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
