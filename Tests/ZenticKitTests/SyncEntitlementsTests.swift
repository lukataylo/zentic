import Foundation
import Testing

/// The app has two entitlements files because iCloud's entries need a
/// provisioning profile the plain build must not (see project.yml). They must
/// differ by exactly those entries: a camera entitlement added to one and not
/// the other would break video calls in only one kind of build.
@Suite struct SyncEntitlementsTests {
    private static let app = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App")

    private func entitlements(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.app.appending(path: name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theICloudFileIsThePlainOnePlusICloudOnly() throws {
        let plain = try entitlements("Zentic.entitlements")
        var cloud = try entitlements("Zentic-iCloud.entitlements")
        #expect(cloud["com.apple.developer.icloud-container-identifiers"] as? [String] == ["iCloud.com.lukadadiani.Zentic"])
        #expect(cloud["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(cloud["com.apple.developer.aps-environment"] != nil)
        for key in ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
            "com.apple.developer.aps-environment"]
        {
            cloud[key] = nil
        }
        #expect(NSDictionary(dictionary: cloud) == NSDictionary(dictionary: plain))
    }
}
