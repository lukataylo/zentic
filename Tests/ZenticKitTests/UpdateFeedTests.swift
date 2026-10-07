import Foundation
import Testing

/// Invariant 7: an update check is one of the few outbound calls, and it may
/// only ask this repository's releases for the signed feed, sending no
/// system profile with it.
@Suite struct UpdateFeedTests {
    private static let info = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Info.plist")

    @Test func checksOnlyThisRepositorysSignedFeedAndSendsNoProfile() throws {
        let data = try Data(contentsOf: Self.info)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let feed = try #require((plist["SUFeedURL"] as? String).flatMap(URL.init(string:)))
        #expect(feed.scheme == "https")
        #expect(feed.host() == "github.com")
        #expect(feed.path().hasPrefix("/lukataylo/zentic/releases/"))
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUEnableSystemProfiling"] as? Bool != true)
        #expect(plist["SUSendProfileInfo"] as? Bool != true)
    }
}
