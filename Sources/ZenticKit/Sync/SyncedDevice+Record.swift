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
    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType,
            let name = record[Field.name] as? String,
            let modified = record[Field.modified] as? Date,
            let data = record[Field.spaces] as? Data,
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version <= Self.payloadVersion
        else { return nil }
        let kind = (record[Field.kind] as? String).flatMap(Kind.init) ?? .desktop
        self.init(id: record.recordID.recordName, name: name, kind: kind, modified: modified, spaces: payload.spaces)
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
