import CloudKit
import Foundation

/// How a `SyncedDevice` is stored in CloudKit: one `Device` record per Mac,
/// named by the device's id, in the private database.
///
/// The name, kind and send time are plain fields; the spaces are one JSON
/// blob, versioned, so a Mac running an older Zentic skips a layout it does
/// not understand instead of misreading it.
extension SyncedDevice {
    public static let recordType = "Device"
    public static let payloadVersion = 1

    private enum Field {
        static let name = "name"
        static let kind = "kind"
        static let modified = "modified"
        static let spaces = "spaces"
    }

    private struct Payload: Codable {
        var version: Int
        var spaces: [Space]
    }

    public func recordID(in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zone)
    }

    /// Write this device's fields onto `record` — a fresh one, or one rebuilt
    /// from the system fields of the last save, so CloudKit sees an update of
    /// its own record rather than a conflicting new one.
    public func write(to record: CKRecord) throws {
        record[Field.name] = name as NSString
        record[Field.kind] = kind.rawValue as NSString
        record[Field.modified] = modified as NSDate
        record[Field.spaces] = try JSONEncoder().encode(Payload(version: Self.payloadVersion, spaces: spaces)) as NSData
    }

    /// Nil for a record this version cannot read: missing fields, or spaces
    /// written by a newer Zentic.
    ///
    /// Only web addresses are kept. A click on a synced tab loads it, so a
    /// `javascript:` or `file:` address in a record — however it got there —
    /// must never reach a tab.
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let name = record[Field.name] as? String,
            let modified = record[Field.modified] as? Date,
            let data = record[Field.spaces] as? Data,
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version <= Self.payloadVersion
        else { return nil }
        let kind = (record[Field.kind] as? String).flatMap(Kind.init) ?? .desktop
        let spaces = payload.spaces.map { space in
            var space = space
            space.pinned.removeAll { !SiteKey.isWeb($0.url) }
            space.tabs.removeAll { !SiteKey.isWeb($0.url) }
            return space
        }
        self.init(id: record.recordID.recordName, name: name, kind: kind, modified: modified, spaces: spaces)
    }
}

extension SyncedDevices {
    /// A fetch's changes. CKSyncEngine fetches every zone in the private
    /// database, and each isolated run (`ZENTIC_DATA_DIR`) keeps its device in
    /// a zone of its own: only records in `zone` are this install's other
    /// Macs, and `ownID`'s record is this Mac, not another one.
    public mutating func apply(
        fetched records: [CKRecord], deleted: [CKRecord.ID], in zone: CKRecordZone.ID, ownID: String
    ) {
        for record in records where record.recordID.zoneID == zone && record.recordID.recordName != ownID {
            if let device = SyncedDevice(record: record) { apply(device) }
        }
        for id in deleted where id.zoneID == zone {
            remove(id: id.recordName)
        }
    }
}

extension CKRecord {
    /// Only the fields CloudKit needs to recognise a later save as an update
    /// (id, change tag) — kept between launches so the first send after one
    /// is not a conflict.
    public var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public convenience init?(systemFields data: Data) {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        self.init(coder: coder)
        coder.finishDecoding()
    }
}
