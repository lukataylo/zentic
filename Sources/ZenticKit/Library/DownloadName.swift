import Foundation

/// Where a download is saved: the server's suggested name, made safe and
/// numbered like the Finder does ("report 2.pdf") when the name is taken.
public enum DownloadName {
    /// `taken` says whether a file is already there or claimed: the disk
    /// alone is not enough, because two downloads of the same name can both
    /// be choosing before WebKit has created either file.
    public static func unused(for suggested: String, in folder: URL, taken: (URL) -> Bool) -> URL {
        // A server's suggestion is a name, not a path: `../` must not walk
        // out of the Downloads folder, and a leading dot would hide the file.
        let cleaned = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? "download" + cleaned : cleaned
        var url = folder.appendingPathComponent(name, isDirectory: false)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while taken(url) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)", isDirectory: false)
            n += 1
        }
        return url
    }
}
