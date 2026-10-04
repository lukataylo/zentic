import Foundation

/// What another app hands Zentic to open — a link, an HTML file, a web
/// archive, or a saved link file (`.webloc`, `.url`) — turned into the address
/// a tab should load.
public enum IncomingURL {
    /// The address to load, or nil for anything a browser should not open.
    ///
    /// Reads the file for a saved link, so call it off the main thread.
    public static func resolve(_ url: URL) -> URL? {
        if isWeb(url) { return url }
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "webloc":
            return (try? Data(contentsOf: url)).flatMap(webloc)
        case "url":
            return (try? String(contentsOf: url, encoding: .utf8)).flatMap(internetShortcut)
        default:
            // An HTML page or web archive, loaded from where it sits.
            return url
        }
    }

    /// The link inside a Finder `.webloc`: a property list, XML or binary,
    /// with the address under `URL`.
    static func webloc(_ data: Data) -> URL? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return ((plist as? [String: Any])?["URL"] as? String).flatMap(webAddress)
    }

    /// The link inside a Windows `.url` internet shortcut: an INI file with
    /// a `URL=` line under `[InternetShortcut]`.
    static func internetShortcut(_ text: String) -> URL? {
        var inSection = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.caseInsensitiveCompare("[InternetShortcut]") == .orderedSame
            } else if inSection, let equals = line.firstIndex(of: "="),
                line[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("URL") == .orderedSame
            {
                return webAddress(String(line[line.index(after: equals)...]))
            }
        }
        return nil
    }

    /// Only a web address may come out of a saved link: one pointing at a
    /// `file:` or `javascript:` URL would turn a double-click on a downloaded
    /// file into something else entirely.
    private static func webAddress(_ string: String) -> URL? {
        URL(string: string.trimmingCharacters(in: .whitespaces)).flatMap { isWeb($0) ? $0 : nil }
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }
}
