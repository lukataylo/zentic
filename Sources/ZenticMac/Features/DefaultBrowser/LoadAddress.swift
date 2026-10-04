import WebKit

extension WKWebView {
    /// A web address, or a file from disk. A file is given read access to
    /// its folder, so a saved page finds the images and stylesheets beside it.
    func load(address url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }
}
