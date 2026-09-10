import Foundation
import CloudKit
import Observation

/// Everything that syncs, and the record type it becomes in CloudKit.
nonisolated enum SyncType: String, CaseIterable {
    case item = "Item"
    case dayMark = "DayMark"
    case schoolTerm = "SchoolTerm"
    case school = "School"
    case calendar = "CalendarTag"
}

/// CloudKit sync and sharing for the household calendar.
///
/// Two decisions shape everything here.
///
/// **One zone, shared whole.** CloudKit shares a zone or a record hierarchy, not
/// a filter — so sharing "just the family calendar" would mean a zone per
/// calendar, doubling the sync bookkeeping for a household that almost always
/// wants to see everything anyway. One `Household` zone is shared in its
/// entirety; per-calendar sharing is a later change, not a blocked one.
///
/// **Records carry JSON, not columns.** Each model is encoded whole into a
/// single `payload` field rather than mapped property by property. The dataset
/// is tiny and always fetched in full, so there is nothing to gain from
/// server-side queries, and adding a field to `Item` doesn't mean a schema
/// change in the CloudKit dashboard and a migration for anyone who hasn't
/// updated. The record type and name are the only structure CloudKit sees.
@MainActor
@Observable
final class CloudSync {

    static let shared = CloudSync()

    static let zoneName = "Household"

    enum Status: Equatable {
        case off
        case starting
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .off:                 return "Off"
            case .starting:            return "Starting…"
            case .ready:               return "Syncing"
            case .failed(let reason):  return reason
            }
        }
    }

    private(set) var status: Status = .off
    private(set) var isShared = false
    private(set) var participants: [String] = []

    /// Whatever container the iCloud entitlement declares.
    ///
    /// Previously this was a hardcoded string that had to be edited to match the
    /// container created in Xcode — miss that step and CloudKit fails with
    /// "BadContainer", which says nothing about a placeholder needing changing.
    /// Taking the default means the entitlement is the single source of truth
    /// and there's nothing to keep in step.
    let container = CKContainer.default()

    var containerName: String { container.containerIdentifier ?? "none" }
    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?

    /// Set by `Store` at launch. Weak-ish by construction: the store outlives us.
    private(set) weak var store: Store?

    let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

    // MARK: Lifecycle

    func start(store: Store) async {
        guard privateEngine == nil else { return }
        self.store = store
        status = .starting

        do {
            guard let identifier = container.containerIdentifier,
                  identifier.hasPrefix("iCloud.")
            else {
                status = .failed("No iCloud container. Add the iCloud capability with CloudKit ticked.")
                return
            }

            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .failed("Sign in to iCloud to sync.")
                return
            }

            privateEngine = makeEngine(for: container.privateCloudDatabase, stateKey: "sync.private")
            sharedEngine = makeEngine(for: container.sharedCloudDatabase, stateKey: "sync.shared")

            // Everything local is offered up on first run; CloudKit works out
            // what it already has.
            if !hasSyncedBefore {
                queueEverything()
                hasSyncedBefore = true
            }

            status = .ready
            await refreshShareState()
        } catch let error as CKError where error.code == .badContainer || error.code == .missingEntitlement {
            // Worth naming, because the generic text sends people looking in the
            // wrong place entirely.
            status = .failed("Container \(containerName) isn't set up in this app's iCloud capability.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func makeEngine(for database: CKDatabase, stateKey: String) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadState(stateKey),
            delegate: self
        )
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }

    // MARK: Local changes

    /// Forgets everything CloudKit-side and starts again from what's on disk.
    ///
    /// Sync can get stuck in ways no amount of retrying fixes — a half-migrated
    /// schema, metadata for records that were wiped server-side. Rather than
    /// leave that as a reinstall, this drops the local metadata and re-offers
    /// every record.
    func resetAndResync() async {
        privateEngine = nil
        sharedEngine = nil
        UserDefaults.standard.removeObject(forKey: "sync.systemFields")
        UserDefaults.standard.removeObject(forKey: "sync.private")
        UserDefaults.standard.removeObject(forKey: "sync.shared")
        hasSyncedBefore = false
        status = .off

        guard let store else { return }
        await start(store: store)
    }

    func recordChanged(_ type: SyncType, id: String) {
        guard let engine = privateEngine else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(type, id))])
    }

    func recordDeleted(_ type: SyncType, id: String) {
        guard let engine = privateEngine else { return }
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(type, id))])
    }

    private func queueEverything() {
        guard let store, let engine = privateEngine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(
            pendingRecordZoneChanges: store.syncableIDs().map { .saveRecord(recordID($0.type, $0.id)) }
        )
    }

    private func recordID(_ type: SyncType, _ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type.rawValue)-\(id)", zoneID: zoneID)
    }

    private func parse(_ recordID: CKRecord.ID) -> (type: SyncType, id: String)? {
        let name = recordID.recordName
        guard let separator = name.firstIndex(of: "-") else { return nil }
        guard let type = SyncType(rawValue: String(name[name.startIndex..<separator])) else { return nil }
        return (type, String(name[name.index(after: separator)...]))
    }

    // MARK: Sharing

    /// The share for the whole zone, created on first use.
    func shareForZone() async throws -> CKShare {
        let database = container.privateCloudDatabase

        if let existing = try? await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare {
            return existing
        }

        // Make sure the zone exists before trying to share it.
        _ = try? await database.save(CKRecordZone(zoneID: zoneID))

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Almanac" as CKRecordValue
        let saved = try await database.save(share)
        guard let result = saved as? CKShare else {
            throw CKError(.internalError)
        }
        return result
    }

    func refreshShareState() async {
        guard let share = try? await shareForZone() else {
            isShared = false
            participants = []
            return
        }
        // The owner is always a participant, so a share is only "shared" once
        // somebody else is on it.
        let others = share.participants.filter { $0.role != .owner }
        isShared = !others.isEmpty
        participants = others.compactMap {
            $0.userIdentity.nameComponents.map { components in
                PersonNameComponentsFormatter().string(from: components)
            } ?? $0.userIdentity.lookupInfo?.emailAddress
        }
    }

    func stopSharing() async {
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try? await database.deleteRecord(withID: shareID)
        await refreshShareState()
    }

    /// Called when someone taps a share link. Accepting pulls the zone into
    /// their shared database, where the second engine picks it up.
    func accept(_ metadata: CKShare.Metadata) async {
        do {
            _ = try await container.accept(metadata)
            try await sharedEngine?.fetchChanges()
        } catch {
            status = .failed("Couldn't accept the invitation: \(error.localizedDescription)")
        }
    }

    // MARK: Record metadata

    /// CloudKit's own fields for each record — most importantly the change tag
    /// that says which version we last saw.
    ///
    /// Without these, every save is built from scratch and the server reads it
    /// as an insert: fine the first time, "record to insert already exists"
    /// every time after. Keeping them turns saves into updates.
    private var systemFields: [String: Data] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "sync.systemFields"),
                  let map = try? JSONDecoder().decode([String: Data].self, from: data)
            else { return [:] }
            return map
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "sync.systemFields")
        }
    }

    private func remember(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()

        var map = systemFields
        map[record.recordID.recordName] = coder.encodedData
        systemFields = map
    }

    private func forget(_ recordID: CKRecord.ID) {
        var map = systemFields
        map.removeValue(forKey: recordID.recordName)
        systemFields = map
    }

    /// A record carrying the server's metadata where we have it, so the save is
    /// an update rather than an insert.
    private func record(for recordID: CKRecord.ID, type: SyncType) -> CKRecord {
        guard let data = systemFields[recordID.recordName],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        else {
            return CKRecord(recordType: type.rawValue, recordID: recordID)
        }
        coder.requiresSecureCoding = true
        let existing = CKRecord(coder: coder)
        coder.finishDecoding()
        return existing ?? CKRecord(recordType: type.rawValue, recordID: recordID)
    }

    // MARK: Engine state

    private var hasSyncedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "sync.hasSynced") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.hasSynced") }
    }

    private func loadState(_ key: String) -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func save(_ state: CKSyncEngine.State.Serialization, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSync: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            let key = syncEngine.database.databaseScope == .private ? "sync.private" : "sync.shared"
            save(update.stateSerialization, key: key)

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                remember(modification.record)
                apply(modification.record)
            }
            for deletion in changes.deletions {
                forget(deletion.recordID)
                guard let parsed = parse(deletion.recordID) else { continue }
                store?.applyRemoteDelete(type: parsed.type, id: parsed.id)
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                remember(record)
            }
            for deletion in sent.deletedRecordIDs {
                forget(deletion)
            }

            for failure in sent.failedRecordSaves {
                let recordID = failure.record.recordID

                switch failure.error.code {
                case .serverRecordChanged:
                    // The server has a version we hadn't seen. Adopt its
                    // metadata and send ours again, so the later edit wins
                    // rather than the save simply failing forever.
                    if let serverRecord = failure.error.serverRecord {
                        remember(serverRecord)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }

                case .unknownItem:
                    // Gone from the server; drop the stale metadata so the next
                    // attempt is a clean insert.
                    forget(recordID)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

                case .zoneNotFound:
                    forget(recordID)
                    syncEngine.state.add(
                        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
                    )
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

                default:
                    break
                }
            }

        case .accountChange:
            await refreshShareState()

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        // Built here rather than through the batch's record-provider closure.
        // That closure runs outside the actor, so it can't reach the store —
        // and this method is already on the main actor, so assembling the
        // records up front needs no hops and no sendable gymnastics.
        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []

        for change in pending {
            switch change {
            case .saveRecord(let recordID):
                guard let parsed = parse(recordID),
                      let payload = store?.payload(for: parsed.type, id: parsed.id)
                else {
                    // Gone locally between queueing and sending: drop the change
                    // rather than leaving it pending forever.
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    continue
                }
                let outgoing = record(for: recordID, type: parsed.type)
                outgoing["payload"] = payload as CKRecordValue
                toSave.append(outgoing)

            case .deleteRecord(let recordID):
                toDelete.append(recordID)

            @unknown default:
                continue
            }
        }

        guard !toSave.isEmpty || !toDelete.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: toSave,
            recordIDsToDelete: toDelete,
            atomicByZone: false
        )
    }

    private func apply(_ record: CKRecord) {
        guard let parsed = parse(record.recordID),
              let payload = record["payload"] as? Data
        else { return }
        store?.applyRemote(type: parsed.type, id: parsed.id, payload: payload)
    }
}
