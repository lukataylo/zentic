import Foundation

/// Saved per-origin designs.
///
/// A redesign is expensive to generate and cheap to keep, so it is generated once
/// and then belongs to the site: visit theverge.com again next week and the design
/// you made for it is already there, with no model call and no wait. That is the
/// difference between a party trick and a browser that looks the way you want.
///
/// A JSON file rather than a SwiftData model, deliberately. The session store
/// holds tabs and history — things that change constantly and must survive a
/// crash mid-write. Designs change once in a while and are trivially regenerable,
/// so they do not justify a schema migration on an existing store, and a plain
/// file is inspectable and portable in a way a `.store` is not.
public actor DesignStore {
    /// The default design applied to every site with no design of its own.
    private static let globalKey = "*"

    private let url: URL
    private var designs: [String: ReaderTheme]
    private var loaded = false

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        self.designs = [:]
    }

    public static func defaultURL() -> URL {
        let directory = URL.applicationSupportDirectory.appending(
            path: "Zentic",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Designs.json")
    }

    /// The design for an origin: its own if it has one, otherwise the global
    /// default, otherwise nil.
    public func design(for origin: String?) -> ReaderTheme? {
        load()
        if let origin, let specific = designs[origin] { return specific }
        return designs[Self.globalKey]
    }

    /// Whether this origin has a design of its own, as opposed to inheriting the
    /// global one. The UI needs the distinction to offer "reset this site".
    public func hasOwnDesign(for origin: String) -> Bool {
        load()
        return designs[origin] != nil
    }

    public func save(_ theme: ReaderTheme, for origin: String?) {
        load()
        designs[origin ?? Self.globalKey] = theme
        persist()
    }

    public func remove(origin: String?) {
        load()
        designs[origin ?? Self.globalKey] = nil
        persist()
    }

    public func removeAll() {
        designs = [:]
        loaded = true
        persist()
    }

    /// Origins with a saved design, for a preferences list.
    public func origins() -> [String] {
        load()
        return designs.keys.filter { $0 != Self.globalKey }.sorted()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        // A design file from an older build that no longer decodes is not worth an
        // error: the user loses a theme they can regenerate, and the alternative is
        // a browser that will not start.
        designs = (try? JSONDecoder().decode([String: ReaderTheme].self, from: data)) ?? [:]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(designs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
