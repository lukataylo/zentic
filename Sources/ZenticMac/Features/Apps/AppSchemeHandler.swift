import Foundation
import WebKit
import ZenticKit

/// Serves `zentic://<app-id>/…`: generated apps, their runtime, their data and
/// their images.
///
/// This is where an app's scope is enforced, so every request is checked against
/// the app the *document* belongs to — `mainDocumentURL`, which WebKit sets and
/// page script cannot — rather than anything the request says about itself. A
/// web page that embeds `zentic://…` gets nothing: its main document is not an
/// app.
@MainActor
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = AppSchemeHandler()

    /// Tasks WebKit has stopped. Responding to one raises, so every async reply
    /// checks first.
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        stopped.remove(ObjectIdentifier(task))
        // The document itself may arrive without a main document URL; every
        // *sub*resource must name its app's document. A request with none — a
        // ping, a prefetch from some other page — gets nothing.
        let isDocument = ["", "/", "/index.html"].contains(task.request.url?.path() ?? "-")
        guard let url = task.request.url,
            let appID = GeneratedApp.id(from: url),
            let main = task.request.mainDocumentURL ?? (isDocument ? url : nil),
            GeneratedApp.id(from: main) == appID
        else {
            respond(task, status: 403, type: "text/plain", body: Data("Forbidden".utf8))
            return
        }
        Task { @MainActor in await route(task, url: url, appID: appID) }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func route(_ task: any WKURLSchemeTask, url: URL, appID: String) async {
        let apps = Apps.shared
        let path = url.path()
        guard let app = apps.app(appID) else {
            respond(task, status: 404, type: "text/html; charset=utf-8", body: Data(Self.missingAppPage.utf8))
            return
        }

        switch path {
        case "", "/", "/index.html":
            guard let html = await apps.store.html(id: appID) else {
                respond(task, status: 404, type: "text/html; charset=utf-8", body: Data(Self.missingAppPage.utf8))
                return
            }
            let nonce = AppSandbox.makeNonce()
            let config = (try? JSONSerialization.data(withJSONObject: ["appID": appID, "name": app.name]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            let document = AppSandbox.document(html: html, appID: appID, nonce: nonce, configJSON: config)
            respond(
                task, status: 200, type: "text/html; charset=utf-8", body: Data(document.utf8),
                headers: ["Content-Security-Policy": AppSandbox.contentSecurityPolicy(appID: appID, nonce: nonce)])

        case AppSandbox.runtimePath:
            respond(task, status: 200, type: "text/javascript; charset=utf-8", body: AppSandbox.runtimeSource)

        case "/_zentic/query":
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value ?? "{}"
            let query: RecordQuery
            do {
                query = try LibraryCoding.decoder().decode(RecordQuery.self, from: Data(raw.utf8))
            } catch {
                // Loud, not lenient. A typo'd filter that silently became "no
                // filter" would show a "last 24 hours" app everything ever captured.
                respond(task, status: 400, type: "text/plain", body: Data("Bad query: \(error)".utf8))
                return
            }
            let records = await apps.records(query, for: app)
            let remote = records.flatMap {
                [$0.authorAvatar].compactMap { $0 } + $0.media.prefix(LibraryBudget.cachedMediaPerRecord)
            }
            // Only what is already cached. An app's query never causes a fetch: that
            // would be a network request outside the sandbox, chosen by the app.
            let cached = await apps.media.cachedKeys(for: remote)
            apps.noteServedMedia(cached.values, for: appID)
            let body = (try? LibraryCoding.encoder().encode(AppSandbox.exposed(records, cachedKeys: cached, appID: appID)))
                ?? Data("[]".utf8)
            respond(task, status: 200, type: "application/json", body: body)

        case "/_zentic/sources":
            let formatter = ISO8601DateFormatter()
            let out: [[String: Any]] = app.sources.map { origin in
                let source = apps.source(origin)
                return [
                    "origin": origin,
                    "title": source?.title ?? origin,
                    "recordCount": apps.recordCounts[origin] ?? 0,
                    "lastCapturedAt": source?.lastCapturedAt.map(formatter.string(from:)) ?? NSNull(),
                    "refresh": source?.refresh.rawValue ?? "browse",
                ]
            }
            respond(
                task, status: 200, type: "application/json",
                body: (try? JSONSerialization.data(withJSONObject: out)) ?? Data("[]".utf8))

        default:
            let key = String(path.dropFirst("/media/".count))
            if path.hasPrefix("/media/"), apps.mayServeMedia(key, to: appID),
                let image = await apps.media.image(forKey: key)
            {
                respond(
                    task, status: 200, type: image.mimeType, body: image.data,
                    headers: ["Cache-Control": "max-age=31536000, immutable"])
            } else {
                respond(task, status: 404, type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    private func respond(
        _ task: any WKURLSchemeTask, status: Int, type: String, body: Data, headers: [String: String] = [:]
    ) {
        if stopped.remove(ObjectIdentifier(task)) != nil { return }
        guard let url = task.request.url else { return }
        var fields = headers
        fields["Content-Type"] = type
        fields["Content-Length"] = String(body.count)
        fields["Cache-Control"] = fields["Cache-Control"] ?? "no-store"
        fields["X-Content-Type-Options"] = "nosniff"
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
        else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    static let missingAppPage = """
        <!doctype html><meta charset="utf-8"><title>App not found</title>
        <style>
        :root { color-scheme: light dark; font: 15px -apple-system, system-ui; }
        body { display: grid; place-items: center; min-height: 90vh; margin: 0; color: #888; }
        </style>
        <p>This app no longer exists.</p>
        """
}
