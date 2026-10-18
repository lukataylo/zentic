import Foundation
import SQLite3

/// The library: every source the user added, every record captured from them,
/// and the raw responses those records were mapped from.
///
/// SQLite rather than SwiftData, for two reasons the session store does not
/// share. Records arrive in bursts of forty from a scroll and are upserted on a
/// composite key, which SwiftData has no primitive for; and the store must be
/// deletable as one file — "forget everything Zentic captured" is a promise, and
/// a separate file is the only way to keep it without touching the session.
///
/// ## Raw responses
///
/// Kept, capped per source (``LibraryBudget/rawResponsesPerSource``). A recipe that
/// breaks when a site changes shape is fixed by re-inferring it — and the
/// responses captured while it was broken are re-mapped from here instead of
/// being lost. That is the difference between an adapter outage costing a day of
/// data and costing nothing.
///
/// Not thread-safe on its own and not `Sendable`: it is owned by ``SourceLibrary``, an
/// actor, and reached only through it. One owner means one serial queue of
/// writes, which is all SQLite asks for.
public final class RecordStore {
    public enum StoreError: Error {
        case sqlite(String)
    }

    private var db: OpaquePointer?
    private let encoder = LibraryCoding.encoder()
    private let decoder = LibraryCoding.decoder()

    /// `Records.sqlite` in the ``DataDirectory`` — so an isolated or test run
    /// never reads or writes the library of the copy someone is browsing with.
    public static var defaultURL: URL {
        DataDirectory.root.appending(path: "Records.sqlite")
    }

    /// - Parameter url: The database file, or nil for an in-memory store (tests).
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let path = url?.path(percentEncoded: false) ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        db = handle
        try Self.migrate(handle)
    }

    deinit { sqlite3_close(db) }

    private static func migrate(_ db: OpaquePointer?) throws {
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS source (
                origin TEXT PRIMARY KEY,
                body BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS raw (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                origin TEXT NOT NULL,
                endpoint TEXT NOT NULL,
                url TEXT NOT NULL,
                captured_at REAL NOT NULL,
                body BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS raw_by_endpoint ON raw(origin, endpoint);
            CREATE TABLE IF NOT EXISTS record (
                source TEXT NOT NULL,
                id TEXT NOT NULL,
                kind TEXT NOT NULL,
                sort_at REAL NOT NULL,
                thread_id TEXT,
                parent_id TEXT,
                author_handle TEXT,
                mentions TEXT NOT NULL DEFAULT '',
                search TEXT NOT NULL,
                body BLOB NOT NULL,
                PRIMARY KEY (source, id)
            );
            CREATE INDEX IF NOT EXISTS record_by_time ON record(source, sort_at);
            CREATE INDEX IF NOT EXISTS record_by_thread ON record(source, thread_id);
            CREATE INDEX IF NOT EXISTS record_by_author ON record(source, author_handle);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Sources

    public func sources() throws -> [Source] {
        try rows("SELECT body FROM source ORDER BY origin") { statement in
            try decoder.decode(Source.self, from: blob(statement, 0))
        }
    }

    public func source(_ origin: String) throws -> Source? {
        try rows("SELECT body FROM source WHERE origin = ?", [.text(origin)]) { statement in
            try decoder.decode(Source.self, from: blob(statement, 0))
        }.first
    }

    public func save(_ source: Source) throws {
        try run(
            "INSERT INTO source (origin, body) VALUES (?, ?) ON CONFLICT(origin) DO UPDATE SET body = excluded.body",
            [.text(source.origin), .blob(try encoder.encode(source))]
        )
    }

    /// Remove a source and everything captured from it.
    public func remove(origin: String) throws {
        try run("DELETE FROM record WHERE source = ?", [.text(origin)])
        try run("DELETE FROM raw WHERE origin = ?", [.text(origin)])
        try run("DELETE FROM source WHERE origin = ?", [.text(origin)])
    }

    // MARK: - Raw responses

    public struct RawResponse: Sendable {
        public var origin: String
        public var endpoint: String
        public var url: String
        public var capturedAt: Date
        public var body: Data
    }

    public func appendRaw(_ raw: RawResponse) throws {
        try run(
            "INSERT INTO raw (origin, endpoint, url, captured_at, body) VALUES (?, ?, ?, ?, ?)",
            [.text(raw.origin), .text(raw.endpoint), .text(raw.url), .real(raw.capturedAt.timeIntervalSince1970), .blob(raw.body)]
        )
        // Keep the newest N per source. Run on every insert, because a cap enforced
        // "later" is a cap a long scroll session blows straight through.
        try run(
            """
            DELETE FROM raw WHERE origin = ? AND seq NOT IN (
                SELECT seq FROM raw WHERE origin = ? ORDER BY seq DESC LIMIT ?
            )
            """,
            [.text(raw.origin), .text(raw.origin), .int(LibraryBudget.rawResponsesPerSource)]
        )
    }

    /// Stored responses for one endpoint, oldest first — the order they are
    /// re-mapped in, so a newer capture's fields win.
    public func rawResponses(origin: String, endpoint: String? = nil) throws -> [RawResponse] {
        var sql = "SELECT origin, endpoint, url, captured_at, body FROM raw WHERE origin = ?"
        var bindings: [Binding] = [.text(origin)]
        if let endpoint {
            sql += " AND endpoint = ?"
            bindings.append(.text(endpoint))
        }
        sql += " ORDER BY seq"
        return try rows(sql, bindings) { statement in
            RawResponse(
                origin: text(statement, 0) ?? "",
                endpoint: text(statement, 1) ?? "",
                url: text(statement, 2) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                body: blob(statement, 4)
            )
        }
    }

    // MARK: - Records

    /// Insert or refresh records. A record seen again keeps its `firstSeen` and
    /// takes everything else from the newer capture — metrics move, text gets
    /// edited, an avatar changes.
    @discardableResult
    public func upsert(_ records: [SourceRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }
        try run("BEGIN")
        do {
            for var record in records {
                // An unreadable stored row is replaced, not allowed to fail the batch.
                if let existing = try? self.record(source: record.source, id: record.id) {
                    record.firstSeen = min(existing.firstSeen, record.firstSeen)
                    record.lastSeen = max(existing.lastSeen, record.lastSeen)
                    // A capture that lacks a field the earlier one had — a thread
                    // response without metrics, say — is not news that it vanished.
                    record.title = record.title ?? existing.title
                    record.text = record.text ?? existing.text
                    record.author = record.author ?? existing.author
                    record.authorHandle = record.authorHandle ?? existing.authorHandle
                    record.authorAvatar = record.authorAvatar ?? existing.authorAvatar
                    record.publishedAt = record.publishedAt ?? existing.publishedAt
                    record.url = record.url ?? existing.url
                    record.parentID = record.parentID ?? existing.parentID
                    record.threadID = record.threadID ?? existing.threadID
                    if record.media.isEmpty { record.media = existing.media }
                    if record.mentions.isEmpty { record.mentions = existing.mentions }
                    if record.links.isEmpty { record.links = existing.links }
                    record.metrics = existing.metrics.merging(record.metrics) { _, new in new }
                }
                let sortAt = (record.publishedAt ?? record.firstSeen).timeIntervalSince1970
                let search = [record.title, record.text, record.author, record.authorHandle]
                    .compactMap { $0 }.joined(separator: "\n").lowercased()
                try run(
                    """
                    INSERT INTO record (source, id, kind, sort_at, thread_id, parent_id, author_handle, mentions, search, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source, id) DO UPDATE SET
                        kind = excluded.kind, sort_at = excluded.sort_at,
                        thread_id = excluded.thread_id, parent_id = excluded.parent_id,
                        author_handle = excluded.author_handle, mentions = excluded.mentions,
                        search = excluded.search, body = excluded.body
                    """,
                    [
                        .text(record.source), .text(record.id), .text(record.kind.rawValue), .real(sortAt),
                        record.threadID.map(Binding.text) ?? .null,
                        record.parentID.map(Binding.text) ?? .null,
                        record.authorHandle.map { Binding.text($0.lowercased()) } ?? .null,
                        // Delimited, so `instr` matches a whole handle and `bo` is not `bob`.
                        .text(record.mentions.isEmpty ? "" : "|" + record.mentions.joined(separator: "|") + "|"),
                        .text(search), .blob(try encoder.encode(record)),
                    ]
                )
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
        return records.count
    }

    public func record(source: String, id: String) throws -> SourceRecord? {
        try rows("SELECT body FROM record WHERE source = ? AND id = ?", [.text(source), .text(id)]) {
            try decoder.decode(SourceRecord.self, from: blob($0, 0))
        }.first
    }

    /// Records matching a query, restricted to `allowedSources` whatever the
    /// query asked for. The restriction is a parameter rather than something the
    /// caller is trusted to have applied, because the caller is serving a page a
    /// model wrote.
    public func records(matching query: RecordQuery, allowedSources: Set<String>) throws -> [SourceRecord] {
        let requested = query.sources.map(Set.init) ?? allowedSources
        let sources = requested.intersection(allowedSources)
        guard !sources.isEmpty else { return [] }

        var clauses = ["source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ",")))"]
        var bindings: [Binding] = sources.sorted().map(Binding.text)

        if let kinds = query.kinds, !kinds.isEmpty {
            clauses.append("kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))")
            bindings += kinds.map { .text($0.rawValue) }
        }
        if let since = query.since {
            clauses.append("sort_at >= ?")
            bindings.append(.real(since.timeIntervalSince1970))
        }
        if let until = query.until {
            clauses.append("sort_at <= ?")
            bindings.append(.real(until.timeIntervalSince1970))
        }
        if let thread = query.threadID {
            clauses.append("thread_id = ?")
            bindings.append(.text(thread))
        }
        if let handle = query.authorHandle {
            clauses.append("author_handle = ?")
            bindings.append(.text(handle.lowercased()))
        }
        if let handle = query.addressedTo?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased(),
            !handle.isEmpty
        {
            clauses.append(
                """
                (instr(mentions, ?) > 0 OR parent_id IN (
                    SELECT p.id FROM record p WHERE p.source = record.source AND p.author_handle = ?
                )) AND (author_handle IS NULL OR author_handle != ?)
                """
            )
            bindings += [.text("|\(handle)|"), .text(handle), .text(handle)]
        }
        if let search = query.search?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
            clauses.append("instr(search, ?) > 0")
            bindings.append(.text(search.lowercased()))
        }

        let order = query.order == .oldest ? "ASC" : "DESC"
        let limit = min(max(query.limit ?? 200, 1), LibraryBudget.appQueryLimit)
        let offset = max(query.offset ?? 0, 0)
        let sql = "SELECT body FROM record WHERE \(clauses.joined(separator: " AND ")) "
            + "ORDER BY sort_at \(order), id \(order) LIMIT \(limit) OFFSET \(offset)"
        // Per row: one record that no longer decodes must cost that record, not
        // every app's whole query.
        return try rows(sql, bindings) { try? decoder.decode(SourceRecord.self, from: blob($0, 0)) }.compactMap { $0 }
    }

    public func recordCount(source: String) throws -> Int {
        try rows("SELECT COUNT(*) FROM record WHERE source = ?", [.text(source)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    // MARK: - SQLite plumbing

    enum Binding {
        case text(String)
        case real(Double)
        case int(Int)
        case blob(Data)
        case null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .int(let value): sqlite3_bind_int64(statement, index, Int64(value))
            case .null: sqlite3_bind_null(statement, index)
            case .blob(let value):
                _ = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func rows<T>(
        _ sql: String,
        _ bindings: [Binding] = [],
        map: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            out.append(try map(statement))
        }
        return out
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
