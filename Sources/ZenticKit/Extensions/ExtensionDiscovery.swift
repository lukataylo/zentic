import Foundation

/// Finds the Safari Web Extensions that installed apps carry, the way Safari
/// does: an app extension at `Contents/PlugIns/*.appex` whose extension point
/// is Safari's.
public enum ExtensionDiscovery {
    public static let extensionPoint = "com.apple.Safari.web-extension"

    public struct Found: Sendable, Equatable {
        public var bundleID: String
        public var path: URL
        /// The app that ships it, for "from Bitwarden" in Settings.
        public var appName: String
    }

    /// Where apps are installed for everyone and for this user.
    public static var applicationDirectories: [URL] {
        [URL(filePath: "/Applications", directoryHint: .isDirectory), .applicationDirectory]
    }

    /// Every Safari Web Extension in an app inside `directories`, or one
    /// folder below them (Setapp and the like install into a subfolder).
    /// Reads only `Info.plist`s, but a hundred of them on a cold disk is not a
    /// main-thread job.
    public static func appExtensions(in directories: [URL]) -> [Found] {
        let files = FileManager.default
        var found: [Found] = []
        var seen = Set<String>()
        func contents(_ url: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        func scan(app: URL) {
            for appex in contents(app.appending(path: "Contents/PlugIns")) where appex.pathExtension == "appex" {
                guard let info = NSDictionary(contentsOf: appex.appending(path: "Contents/Info.plist")),
                    (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == extensionPoint,
                    let bundleID = info["CFBundleIdentifier"] as? String,
                    seen.insert(bundleID).inserted
                else { continue }
                found.append(Found(bundleID: bundleID, path: appex, appName: app.deletingPathExtension().lastPathComponent))
            }
        }
        for directory in directories {
            for item in contents(directory) {
                if item.pathExtension == "app" {
                    scan(app: item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    contents(item).filter { $0.pathExtension == "app" }.forEach(scan(app:))
                }
            }
        }
        return found.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }
}

/// A key and its modifiers, normalised so a menu item's key equivalent and an
/// extension's keyboard command compare equal when they are the same chord:
/// a menu may spell ⇧⌘L as "L" with ⌘, an extension as "l" with ⇧⌘.
public struct KeyChord: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        var modifiers = modifiers
        let lower = key.lowercased()
        if lower != key { modifiers.insert(.shift) }
        self.key = lower
        self.modifiers = modifiers
    }
}
