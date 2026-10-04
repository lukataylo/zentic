import AppKit
import CloudKit
import Observation
import Security
import ZenticKit

/// iCloud tab sync: this Mac's ordinary windows' spaces and tabs go up as one
/// small record, and every other Mac's come down, through the user's private
/// CloudKit database. Nothing else syncs — no private windows, history, site
/// choices or passwords — and nothing goes anywhere but the user's own iCloud.
///
/// Quiet by design. Sending waits for a burst of changes to settle and is
/// never more often than `SyncPacing.minimumInterval`; an unchanged set of
/// tabs is never sent at all. Without iCloud, or in a build without the
/// entitlement, the feature hides itself rather than reporting errors.
@MainActor
@Observable
final class TabSync {
    static let shared = TabSync()
    static let containerID = "iCloud.com.lukadadiani.Zentic"

    enum Status: Equatable {
        case off
        case starting
        /// Why there is no sync, in words for Settings.
        case unavailable(String)
        case syncing
        case synced(Date?)
    }

    private(set) var status: Status = .off
    /// Other Macs with tabs open, most recently heard from first.
    private(set) var devices: [SyncedDevice] = []
    /// A save CloudKit refused for a reason retrying will not fix (iCloud
    /// full, say). Shown in Settings, never as an alert.
    private(set) var problem: String?

    /// The user's switch. On by default: it does nothing without an iCloud
    /// account, and with one it is what someone with two Macs expects.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: "syncTabs")
            isEnabled ? start() : stop()
        }
    }

    /// Whether this build may use CloudKit at all. `swift run` builds a bare
    /// executable with no entitlements, and touching CloudKit there kills the
    /// process — so it is checked before anything else is.
    static let isSupported: Bool = {
        #if DEBUG
        if fixture != nil { return true }
        #endif
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) == true
    }()

    @ObservationIgnored private let defaults = DataDirectory.defaults
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var cache: Cache?
    /// Waiting to send, per `SyncPacing`.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var lastQueuedAt: Date?
    @ObservationIgnored private var lastFetchAt: Date?
    /// The device as it was when last queued; what the next record is built from.
    @ObservationIgnored private var queued: SyncedDevice?

    private let deviceID: String
    /// Isolated runs (`ZENTIC_DATA_DIR`) get a zone of their own, so a test
    /// launch never shows up as a Mac on the user's real devices.
    private let zoneID = CKRecordZone.ID(
        zoneName: DataDirectory.isIsolated ? "Tabs-\(DataDirectory.isolationID.uuidString)" : "Tabs",
        ownerName: CKCurrentUserDefaultName)
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: deviceID, zoneID: zoneID) }
    private let file = JSONFile<Cache>(name: "sync.json")
    /// Cache writes, in order, off the main thread.
    private let io = DispatchQueue(label: "Zentic.sync", qos: .utility)

    /// What survives a relaunch: the engine's place in the change stream, the
    /// other Macs' tabs (CloudKit only ever sends changes), and what this Mac
    /// last sent, so an unchanged set of tabs is not sent again.
    struct Cache: Codable, Sendable {
        var engineState: CKSyncEngine.State.Serialization?
        /// Our own record's system fields, so a save is an update, not a conflict.
        var systemFields: Data?
        var sent: SyncedDevice?
        var devices = SyncedDevices()
        var lastSynced: Date?
    }

    private init() {
        deviceID = ThisMac.syncID
        isEnabled = DataDirectory.defaults.object(forKey: "syncTabs") as? Bool ?? true

        guard Self.isSupported else { return }
        let center = NotificationCenter.default
        // Signed in to iCloud while waiting for an account. A running engine
        // reports account changes itself, as events.
        center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.engine == nil { self?.start() } }
        }
        // Pushes tell us about changes as they happen; coming back to the app
        // after a while also asks, in case one was missed.
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchIfStale() }
        }
    }

    // MARK: - Starting and stopping

    func start() {
        guard Self.isSupported, isEnabled, engine == nil, !starting else { return }
        #if DEBUG
        if let fixture = Self.fixture {
            devices = (try? JSONDecoder.iso8601.decode([SyncedDevice].self, from: Data(contentsOf: fixture))) ?? []
            status = .synced(devices.first?.modified)
            return
        }
        #endif
        starting = true
        status = .starting
        Task {
            defer { starting = false }
            let file = self.file
            let cache = await Task.detached(priority: .utility) { file.load() ?? Cache() }.value
            let container = CKContainer(identifier: Self.containerID)
            let account = (try? await container.accountStatus()) ?? .couldNotDetermine
            guard isEnabled else { return }
            guard account == .available else {
                devices = []
                status = .unavailable(Self.reason(for: account))
                return
            }
            self.cache = cache
            showDevices()
            let engine = CKSyncEngine(
                .init(database: container.privateCloudDatabase, stateSerialization: cache.engineState, delegate: self))
            self.engine = engine
            if cache.engineState == nil {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
            lastFetchAt = .now  // a new engine fetches by itself
            status = .synced(cache.lastSynced)
            sessionChanged()
        }
    }

    /// Turned off: take this Mac off the others' lists, and forget theirs.
    private func stop() {
        sendTask?.cancel()
        sendTask = nil
        if let engine {
            let recordID = self.recordID
            // Released first, so the events this send raises are ignored.
            self.engine = nil
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            Task { try? await engine.sendChanges() }
        }
        forgetLocalData()
        status = .off
    }

    private func forgetLocalData() {
        cache = nil
        queued = nil
        devices = []
        problem = nil
        let url = file.url
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    private func accountChanged() {
        guard isEnabled else { return }
        // A different account's tabs are not this one's: start over.
        engine = nil
        forgetLocalData()
        start()
    }

    private func fetchIfStale() {
        guard let engine, Date.now.timeIntervalSince(lastFetchAt ?? .distantPast) > 5 * 60 else { return }
        lastFetchAt = .now
        Task { try? await engine.fetchChanges() }
    }

    func syncNow() {
        guard let engine else { return start() }
        sendTask?.cancel()
        sendTask = nil
        queueIfChanged()
        lastFetchAt = .now
        status = .syncing
        Task {
            try? await engine.sendChanges()
            try? await engine.fetchChanges()
            if self.engine === engine { status = .synced(cache?.lastSynced) }
        }
    }

    // MARK: - Sending

    /// The session changed. Costs nothing per change: the tabs are only read
    /// when the paced send comes due.
    func sessionChanged() {
        guard engine != nil, sendTask == nil else { return }
        let due = SyncPacing.nextSend(lastSent: lastQueuedAt, now: .now)
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            self.sendTask = nil
            self.queueIfChanged()
        }
    }

    private func queueIfChanged() {
        guard let engine else { return }
        let current = thisDevice()
        if let sent = cache?.sent, sent.id == current.id, sent.hasSameContent(as: current) { return }
        queued = current
        lastQueuedAt = .now
        // The engine sends it within moments, and retries if offline.
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func thisDevice() -> SyncedDevice {
        SyncedDevice(
            id: deviceID, name: ThisMac.name, kind: ThisMac.kind, modified: .now,
            spaces: SyncedDevice.spaces(from: Windows.shared.snapshot))
    }

    /// Something left to send when quitting.
    var hasUnsentChanges: Bool {
        guard let engine else { return false }
        return sendTask != nil || !engine.state.pendingRecordZoneChanges.isEmpty
    }

    /// Quitting: send what changed since the last send, but never hold the
    /// quit up for long — offline, the engine keeps it for the next launch.
    func sendBeforeQuit(within limit: Duration) async {
        guard let engine else { return }
        sendTask?.cancel()
        sendTask = nil
        queueIfChanged()
        if !engine.state.pendingRecordZoneChanges.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await engine.sendChanges() }
                group.addTask { try? await Task.sleep(for: limit) }
                await group.next()
                group.cancelAll()
            }
        }
        if let cache {
            let file = self.file
            io.sync { file.save(cache) }
        }
    }

    // MARK: - Engine events

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard id == recordID else { return nil }
        let device = queued ?? thisDevice()
        let record =
            cache?.systemFields.flatMap(CKRecord.init(systemFields:)).flatMap { $0.recordID == id ? $0 : nil }
            ?? CKRecord(recordType: SyncedDevice.recordType, recordID: id)
        do {
            try device.write(to: record)
        } catch {
            return nil
        }
        return record
    }

    private func handle(_ event: CKSyncEngine.Event, from source: CKSyncEngine) {
        // An engine already let go of (sync turned off, account changed).
        guard source === engine, cache != nil else { return }
        switch event {
        case .stateUpdate(let update):
            cache?.engineState = update.stateSerialization

        case .accountChange(let change):
            // Signing in, the engine re-sends what is pending by itself.
            if case .signIn = change.changeType {} else { accountChanged() }
            return

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                // Deleted from iCloud settings: the user asked for it gone, so
                // stop rather than put it straight back.
                if deletion.reason == .purged {
                    isEnabled = false
                    return
                }
                // Reset (encryption keys, say): put this Mac back.
                cache?.devices = SyncedDevices()
                cache?.systemFields = nil
                cache?.sent = nil
                source.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                sessionChanged()
            }
            showDevices()

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                if record.recordID == recordID {
                    cache?.systemFields = record.encodedSystemFields
                } else if let device = SyncedDevice(record: record) {
                    cache?.devices.apply(device)
                }
            }
            for deletion in changes.deletions where deletion.recordID != recordID {
                cache?.devices.remove(id: deletion.recordID.recordName)
            }
            showDevices()

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords where record.recordID == recordID {
                cache?.systemFields = record.encodedSystemFields
                cache?.sent = SyncedDevice(record: record)
                cache?.lastSynced = .now
                problem = nil
            }
            for failure in sent.failedRecordSaves where failure.record.recordID == recordID {
                retry(failure.error)
            }
            status = .synced(cache?.lastSynced)

        case .willFetchChanges:
            status = .syncing
        case .didFetchChanges:
            cache?.lastSynced = .now
            status = .synced(cache?.lastSynced)

        default:
            return
        }
        persist()
    }

    /// A save CloudKit refused. Network trouble the engine retries by itself;
    /// these it cannot fix without us.
    private func retry(_ error: CKError) {
        guard let engine else { return }
        switch error.code {
        case .serverRecordChanged:
            // Our record changed on the server since we last saw it (another
            // install with this id, or a lost reply). It is ours: take its
            // change tag and save over it.
            cache?.systemFields = error.serverRecord?.encodedSystemFields
        case .zoneNotFound, .userDeletedZone:
            cache?.systemFields = nil
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        case .unknownItem:
            cache?.systemFields = nil
        case .quotaExceeded:
            problem = "iCloud storage is full."
            return
        default:
            problem = error.localizedDescription
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    private func showDevices() {
        let others = cache?.devices.others(than: deviceID) ?? []
        if others != devices { devices = others }
    }

    private func persist() {
        guard let cache else { return }
        let file = self.file
        io.async { file.save(cache) }
    }

    private static func reason(for status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: "Sign in to iCloud in System Settings to sync tabs."
        case .restricted: "iCloud is restricted on this Mac."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Check System Settings › Apple Account."
        default: "iCloud can’t be reached right now."
        }
    }

    #if DEBUG
    /// A JSON list of devices to show instead of syncing, for looking at the
    /// interface in a build that cannot reach CloudKit. Debug builds only.
    static let fixture: URL? = ProcessInfo.processInfo.environment["ZENTIC_SYNC_FIXTURE"].map { URL(filePath: $0) }
    #endif
}

// MARK: - CKSyncEngineDelegate

extension TabSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await self.record(for: id)
        }
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
