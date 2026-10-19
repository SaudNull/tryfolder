import Foundation
import Darwin

/// Local, descriptor-anchored session storage. A draft is independent content, not an application sandbox.
public actor SessionEngine {
    private let store: SafeDirectory
    private let fault: (@Sendable (String) throws -> Void)?

    public init(storeURL: URL, fault: (@Sendable (String) throws -> Void)? = nil) throws {
        // Native removable-volume permission prompts may pause this open. Do not hold the global mutation lock while waiting.
        let candidate = try SafeDirectory(storeURL, create: true)
        let guardLock = try MutationLock(); defer { withExtendedLifetime(guardLock) {} }
        self.store = candidate
        self.fault = fault
        try store.requireDisjoint(from: guardLock.coordination)
        var info = stat()
        guard fstat(store.fd, &info) == 0, info.st_uid == getuid() else { throw fail("Session storage must belong to this user", storeURL.path) }
        if try store.info(".tryfolder-store") != nil {
            let marker = try DurableJSON.read(StoreMarker.self, from: store, path: ".tryfolder-store")
            guard marker.app == "TryFolder", marker.version == 1, marker.identity == store.identity else { throw fail("Storage marker does not match this directory", storeURL.path) }
        }
    }

    public func listSessions() throws -> [SessionRecord] {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        try store.validate()
        var records: [SessionRecord] = []
        for name in try store.names() {
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let (root, record, _) = try session(id)
            var displayed = record
            if let journal = try readJournal(root) {
                if journal.status == "active" { displayed.state = .recoveryNeeded; displayed.lastMessage = "An unfinished transaction requires recovery; all retained versions are preserved." }
                else if displayed.state == .applying { displayed.state = journal.status == "committed" ? (journal.purpose == "apply" ? .applied : .editing) : journal.originalState }
            } else if displayed.state == .preparing { displayed.state = .interrupted; displayed.lastMessage = "Preparation stopped before a completed draft was recorded; source files were not changed." }
            records.append(displayed)
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    public func create(source input: URL) throws -> SessionRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        try store.validate()
        let sourceURL = try SafePath.canonical(input)
        try SafePath.validateSource(sourceURL); try SafePath.disjoint(sourceURL, store.url)
        let source = try SafeDirectory(sourceURL)
        try store.sameVolume(as: source)
        try store.requireDisjoint(from: source)
        try lock.coordination.requireDisjoint(from: source)
        try source.rejectManagedAncestor()
        // A mounted volume root itself is too broad a selection.
        let parent = try SafeDirectory(sourceURL.deletingLastPathComponent())
        guard parent.device == source.device else { throw fail("Select an ordinary folder below the volume root", sourceURL.path) }
        if try store.info(".tryfolder-store") == nil { try DurableJSON.write(StoreMarker(identity: store.identity), to: store, path: ".tryfolder-store") }
        let id = UUID()
        try store.makeDirectory(id.uuidString)
        let root = try SafeDirectory(store.url.appendingPathComponent(id.uuidString))
        let binding = SourceBinding(sessionID: id, source: sourceURL, identity: source.identity, sessionIdentity: root.identity, sourceAncestors: source.ancestorIdentities)
        var record = SessionRecord(id: id, name: sourceURL.lastPathComponent, sourceURL: sourceURL, sessionURL: root.url, sourceDevice: source.device, sourceInode: source.identity.inode)
        try DurableJSON.write(binding, to: root, path: "binding.json")
        try save(record, root)
        do {
            try check("create.beforeCapture")
            let original = try TreeCapture.scan(source)
            try root.makeDirectory("baseline"); try root.makeDirectory("draft"); try root.makeDirectory("reviews"); try root.makeDirectory("transactions")
            let baseline = try SafeDirectory(record.baselineURL)
            try TreeCapture.copy(original, from: source, to: baseline)
            try check("create.afterBaseline")
            let after = try TreeCapture.scan(source)
            guard original.equivalent(to: after, identities: true) else { throw fail("Source changed during capture; save and close editors before retrying", sourceURL.path) }
            let draft = try SafeDirectory(record.draftURL)
            try TreeCapture.copy(original, from: baseline, to: draft)
            try check("create.afterDraft")
            // The baseline stores original identities separately from its own independent inodes.
            try DurableJSON.write(original, to: root, path: "baseline.json")
            record.state = .editing; record.excluded = original.excluded
            record.lastMessage = "Draft created from a validated baseline. Directory metadata is outside Apply scope; empty source directories are retained."
            try save(record, root); return record
        } catch {
            record.state = .interrupted; record.lastMessage = error.localizedDescription
            try? save(record, root); throw error
        }
    }

    public func review(sessionID: UUID) throws -> ReviewRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, loaded, binding) = try session(sessionID)
        try requireNoPending(root)
        guard [.editing, .readyToApply, .conflict, .reviewing].contains(loaded.state) else { throw fail("This session cannot be reviewed in its current state", loaded.name) }
        var record = loaded; record.state = .reviewing; try save(record, root)
        do {
            let baseline = try baselineTree(root, record)
            let draft = try SafeDirectory(record.draftURL)
            try check("review.beforeSeal")
            let manifest = try TreeCapture.scan(draft)
            let id = UUID(); let relative = "reviews/\(id.uuidString)"
            try root.makeDirectory(relative)
            let snapshot = try SafeDirectory(root.url.appendingPathComponent(relative))
            try TreeCapture.copy(manifest, from: draft, to: snapshot)
            guard manifest.equivalent(to: try TreeCapture.scan(draft), identities: true) else { throw fail("Draft changed during sealing; save and close editors before reviewing", draft.url.path) }
            try check("review.afterSeal")
            var current: CapturedTree?; var unavailable: String?
            do { current = try TreeCapture.scan(try sourceRoot(binding)) }
            catch { unavailable = error.localizedDescription }
            let changes = threeWay(baseline: baseline, current: current, draft: manifest, sourceMessage: unavailable)
            let excluded = Array(Set(record.excluded + manifest.excluded + (current?.excluded ?? []))).sorted { $0.path < $1.path }
            let result = ReviewRecord(id: id, sessionID: record.id, snapshotURL: snapshot.url, changes: changes, excluded: excluded, sourceUnchanged: current.map { baseline.equivalent(to: $0, identities: true) } ?? false, sourceAvailable: current != nil, draftManifest: manifest.files)
            try DurableJSON.write(manifest, to: root, path: "reviews/\(id.uuidString).manifest.json")
            try DurableJSON.write(result, to: root, path: "review.json")
            record.state = changes.contains { $0.kind == .conflict } || current == nil ? .conflict : .readyToApply
            record.lastMessage = current == nil ? "Original unavailable. The sealed draft can still be kept as a new folder." : "Review sealed at \(result.createdAt). Later draft edits require a fresh review."
            try save(record, root); return result
        } catch {
            record.state = .editing; record.lastMessage = error.localizedDescription; try? save(record, root); throw error
        }
    }

    public func loadReview(sessionID: UUID) throws -> ReviewRecord? {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, record, _) = try session(sessionID)
        guard try root.info("review.json") != nil else { return nil }
        return try validatedReview(root, record).0
    }

    public func keep(sessionID: UUID, reviewID: UUID, destination input: URL) throws -> URL {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, record, binding) = try session(sessionID)
        try requireNoPending(root)
        guard record.state != .discarded && record.state != .preparing && record.state != .interrupted else { throw fail("This session cannot be exported", record.name) }
        let (review, manifest, snapshot) = try validatedReview(root, record)
        guard review.id == reviewID else { throw fail("The review changed; refresh before keeping", record.name) }
        let destination = try SafePath.canonical(input)
        try SafePath.disjoint(destination, store.url); try SafePath.disjoint(destination, binding.source)
        let parent = try SafeDirectory(destination.deletingLastPathComponent())
        try parent.sameVolume(as: store)
        try parent.rejectManagedAncestor()
        guard !parent.ancestorIdentities.contains(lock.coordination.identity) else { throw fail("Export destination is inside durable coordination storage", destination.path) }
        guard !parent.ancestorIdentities.contains(store.identity), !parent.ancestorIdentities.contains(binding.identity) else { throw fail("Export destination is inside managed storage or the original by filesystem identity", destination.path) }
        let name = destination.lastPathComponent
        _ = try SafePath.components(name)
        guard try parent.info(name) == nil else { throw fail("Keep requires a nonexistent destination and never merges", destination.path) }
        // Construct the complete export privately, then no-clobber publish a single directory entry.
        let stagingName = ".TryFolder-export-\(UUID().uuidString)"
        try parent.makeDirectory(stagingName)
        let staging = try SafeDirectory(parent.url.appendingPathComponent(stagingName))
        try TreeCapture.copy(manifest, from: snapshot, to: staging)
        try parent.validate(); try snapshot.validate(); try staging.validate()
        guard renameatx_np(parent.fd, stagingName, parent.fd, name, UInt32(RENAME_EXCL)) == 0, fsync(parent.fd) == 0 else { throw posix("Publish verified export without overwrite", destination.path) }
        return destination
    }

    public func discard(sessionID: UUID) throws -> SessionRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, loaded, _) = try session(sessionID)
        try requireNoPending(root)
        guard [.editing, .reviewing, .readyToApply, .conflict, .interrupted, .discarded].contains(loaded.state) else { throw fail("Resolve or undo the applied transaction before discarding", loaded.name) }
        var record = loaded; record.state = .discarded
        record.lastMessage = "Logically archived. Draft, baseline and sealed reviews remain retained in session storage. Exported folders are independent."
        try save(record, root); return record
    }

    public func apply(sessionID: UUID, reviewID: UUID, selectedPaths: Set<String>) throws -> SessionRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, loaded, binding) = try session(sessionID)
        try requireNoPending(root)
        guard [.readyToApply, .conflict].contains(loaded.state), !selectedPaths.isEmpty else { throw fail("Select reviewed, nonconflicting changes before applying", loaded.name) }
        let (review, _, snapshot) = try validatedReview(root, loaded)
        guard review.id == reviewID, review.sourceAvailable else { throw fail("Review no longer matches or original is unavailable", loaded.name) }
        let baseline = try baselineTree(root, loaded)
        let source = try sourceRoot(binding)
        try lock.checkAvailable(source: source)
        var operations: [JournalOperation] = []
        for path in selectedPaths.sorted() {
            try SafePath.allowed(path)
            guard let change = review.changes.first(where: { $0.path == path }), change.canApply else { throw fail("Path is absent, unsupported or conflicted in this review", path) }
            let current = try source.fileEntry(path)
            guard same(current, change.current, identity: true), same(current, baseline.files[path], identity: true) else { throw fail("Original changed after baseline/review; refresh and resolve this conflict", path) }
            let pins = try source.ancestorPins(path)
            for parent in try parentPaths(path) { guard pins[parent] == baseline.directoryIdentities[parent] else { throw fail("Original parent directory changed since baseline", path) } }
            operations.append(JournalOperation(path: path, before: current, after: change.draft, step: "staged", parentPins: pins))
        }
        return try transact(root: root, record: loaded, source: source, reviewID: review.id, purpose: "apply", operations: operations, replacement: snapshot, coordination: lock)
    }

    public func undo(sessionID: UUID) throws -> SessionRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, record, binding) = try session(sessionID)
        try requireNoPending(root)
        guard record.state == .applied else { throw fail("Only an applied session can be undone", record.name) }
        let receipt = try DurableJSON.read(ApplyReceipt.self, from: root, path: "receipt.json")
        try validateReceipt(receipt, root: root, record: record)
        let source = try sourceRoot(binding)
        try lock.checkAvailable(source: source)
        var operations: [JournalOperation] = []
        for operation in receipt.operations {
            let current = try source.fileEntry(operation.path)
            guard same(current, operation.after, identity: true) else { throw fail("Undo conflict: original was edited or replaced after Apply; newer work is preserved", operation.path) }
            let pins = try source.ancestorPins(operation.path)
            guard pins == operation.parentPins else { throw fail("Undo conflict: a source parent directory was replaced", operation.path) }
            operations.append(JournalOperation(path: operation.path, before: current, after: operation.before, step: "staged", parentPins: pins))
        }
        let recovery = try SafeDirectory(root.url.appendingPathComponent("transactions/\(receipt.journalID.uuidString)/before"))
        return try transact(root: root, record: record, source: source, reviewID: receipt.reviewID, purpose: "undo", operations: operations, replacement: recovery, coordination: lock)
    }

    public func recover(sessionID: UUID) throws -> SessionRecord {
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let (root, loaded, binding) = try session(sessionID)
        guard var journal = try readJournal(root) else {
            try lock.checkAvailable(sourceURL: binding.source, sourceIdentity: binding.identity, sourceAncestors: binding.sourceAncestors)
            return loaded
        }
        try validateJournal(journal, root: root, record: loaded)
        let owner = reservationOwner(sessionID: loaded.id, transactionID: journal.id)
        try lock.checkAvailable(sourceURL: binding.source, sourceIdentity: binding.identity, sourceAncestors: binding.sourceAncestors, owner: owner)
        if journal.status == "committed" {
            // Complete the harmless state bookkeeping if the process stopped after the durable commit.
            var record = loaded; record.state = journal.purpose == "apply" ? .applied : .editing
            if journal.purpose == "undo" { try publishUndoGuards(journal, root: root) }
            try lock.release(owner: owner)
            try save(record, root); return record
        }
        if journal.status == "recovered" {
            try lock.release(owner: owner)
            var record = loaded; record.state = journal.originalState; try save(record, root); return record
        }
        if journal.operations.allSatisfy({ $0.step == "staged" }) {
            // The active journal is durable before the cross-store reservation. A crash in that gap
            // permits another legitimate transaction to run, but no source operation from this one
            // was attempted. Cancel it without comparing/overwriting that later source version.
            for index in journal.operations.indices { journal.operations[index].step = "recovered" }
            journal.status = "recovered"; try writeJournal(journal, root)
            try check("recover.afterCommit")
            try lock.release(owner: owner)
            try check("recover.afterRelease")
            var record = loaded; record.state = journal.originalState
            record.lastMessage = "Prepared transaction cancelled before any source mutation. Later original edits and all staged/recovery versions are preserved."
            try save(record, root); return record
        }
        let source = try sourceRoot(binding)
        let transaction = try SafeDirectory(root.url.appendingPathComponent("transactions/\(journal.id.uuidString)"))
        do {
            try lock.reserve(source: source, owner: owner, purpose: journal.purpose)
            try check("recover.afterReservation")
            for index in journal.operations.indices.reversed() {
                let operation = journal.operations[index]
                try source.validate(); try transaction.validate()
                let current = try source.fileEntry(operation.path)
                if same(current, operation.before) {
                    // Untouched or already rolled back. A replacement with identical bytes still remains retained.
                    journal.operations[index].step = "recovered"; try writeJournal(journal, root); continue
                }
                guard same(current, operation.after) else { throw fail("Recovery conflict: original differs from both journal states; all versions retained", operation.path) }
                try source.validateAncestors(operation.path, pins: operation.parentPins)
                if let before = operation.before {
                    let displaced = operation.after == nil ? "displaced/\(operation.path)" : "staged/\(operation.path)"
                    guard same(try transaction.fileEntry(displaced), before, identity: true) else { throw fail("Displaced recovery bytes differ from the verified original; all versions retained", operation.path) }
                }
                try check("recover.beforeMutation")
                try source.validateAncestors(operation.path, pins: operation.parentPins)
                guard same(try source.fileEntry(operation.path), operation.after) else { throw fail("Original changed at recovery boundary", operation.path) }
                if operation.before == nil {
                    try source.rename(operation.path, to: transaction, as: "rolledBack/\(operation.path)", sourcePins: operation.parentPins)
                } else if operation.after == nil {
                    let displaced = "displaced/\(operation.path)"
                    guard try transaction.fileEntry(displaced) != nil else { throw fail("Recovery image missing; refusing to overwrite", operation.path) }
                    guard same(try transaction.fileEntry(displaced), operation.before, identity: true) else { throw fail("Recovery bytes changed at mutation boundary", operation.path) }
                    try transaction.rename(displaced, to: source, as: operation.path, targetPins: operation.parentPins)
                } else {
                    let displaced = "staged/\(operation.path)"
                    guard try transaction.fileEntry(displaced) != nil else { throw fail("Displaced original missing; refusing to overwrite", operation.path) }
                    guard same(try transaction.fileEntry(displaced), operation.before, identity: true) else { throw fail("Recovery bytes changed at mutation boundary", operation.path) }
                    try transaction.rename(displaced, to: source, as: operation.path, swap: true, targetPins: operation.parentPins)
                }
                try check("recover.afterMutation")
                // Restore the ACTUAL displaced bytes if a writer raced the original apply, even if they differ from expected before.
                // Such a divergence is preserved and surfaced rather than replaced with an older recovery copy.
                let restored = try source.fileEntry(operation.path)
                if !same(restored, operation.before) {
                    throw fail("Recovery restored an external version displaced during the original operation; retained material needs review", operation.path)
                }
                journal.operations[index].step = "recovered"; try writeJournal(journal, root)
            }
            journal.status = "recovered"; try writeJournal(journal, root)
            try check("recover.afterCommit")
            try lock.release(owner: owner)
            try check("recover.afterRelease")
            var record = loaded; record.state = journal.originalState
            record.lastMessage = "Interrupted \(journal.purpose) rolled back. Recovery images and reviewed bytes remain retained."
            try save(record, root); return record
        } catch {
            var record = loaded; record.state = .recoveryNeeded; record.lastMessage = error.localizedDescription
            try? save(record, root); throw error
        }
    }

    private func transact(root: SafeDirectory, record loaded: SessionRecord, source: SafeDirectory, reviewID: UUID, purpose: String, operations: [JournalOperation], replacement: SafeDirectory, coordination: MutationLock) throws -> SessionRecord {
        let id = UUID(); let prefix = "transactions/\(id.uuidString)"
        try root.makeDirectory(prefix)
        let transaction = try SafeDirectory(root.url.appendingPathComponent(prefix))
        try transaction.makeDirectory("before"); try transaction.makeDirectory("staged"); try transaction.makeDirectory("displaced"); try transaction.makeDirectory("rolledBack")
        for operation in operations {
            if let before = operation.before {
                try source.copyFile(operation.path, to: transaction, as: "before/\(operation.path)")
                guard before.sameContent(as: try transaction.fileEntry("before/\(operation.path)")) else { throw fail("Recovery image failed verification", operation.path) }
            }
            if let after = operation.after {
                try replacement.copyFile(operation.path, to: transaction, as: "staged/\(operation.path)")
                guard after.sameContent(as: try transaction.fileEntry("staged/\(operation.path)")) else { throw fail("Staged replacement failed verification", operation.path) }
            }
        }
        var journal = MutationJournal(id: id, sessionID: loaded.id, reviewID: reviewID, purpose: purpose, originalState: purpose == "apply" ? .editing : .applied, status: "active", operations: operations)
        try writeJournal(journal, root)
        var record = loaded; record.state = .applying
        var createdParents: [String: NodeIdentity] = [:]
        let owner = reservationOwner(sessionID: loaded.id, transactionID: id)
        do {
            try check("\(purpose).afterJournalPersisted")
            try coordination.reserve(source: source, owner: owner, purpose: purpose)
            try check("\(purpose).afterReservation")
            try save(record, root); try check("\(purpose).afterJournal")
            for index in journal.operations.indices {
                var operation = journal.operations[index]
                try source.validate(); try replacement.validate()
                guard same(try source.fileEntry(operation.path), operation.before, identity: true) else { throw fail("Original changed before mutation; recovery required", operation.path) }
                journal.operations[index].step = "attempted"; try writeJournal(journal, root)
                try check("\(purpose).beforeMutation")
                // Revalidate after fault/editor callbacks, then pin parents opened for the actual rename.
                guard same(try source.fileEntry(operation.path), operation.before, identity: true) else { throw fail("Original changed at mutation boundary", operation.path) }
                operation.parentPins = try source.prepareParents(operation.path, pins: operation.parentPins, created: &createdParents)
                journal.operations[index].parentPins = operation.parentPins; try writeJournal(journal, root)
                if let after = operation.after {
                    guard same(try transaction.fileEntry("staged/\(operation.path)"), after) else { throw fail("Staged reviewed bytes changed at mutation boundary", operation.path) }
                }
                // No destructive unlink. Edits atomically exchange, removals move the actual original into retained recovery.
                if operation.before == nil {
                    try transaction.rename("staged/\(operation.path)", to: source, as: operation.path, targetPins: operation.parentPins)
                } else if operation.after == nil {
                    try source.rename(operation.path, to: transaction, as: "displaced/\(operation.path)", sourcePins: operation.parentPins)
                } else {
                    try transaction.rename("staged/\(operation.path)", to: source, as: operation.path, swap: true, targetPins: operation.parentPins)
                }
                try check("\(purpose).afterMutation")
                if let before = operation.before {
                    let displaced = operation.after == nil ? "displaced/\(operation.path)" : "staged/\(operation.path)"
                    guard same(try transaction.fileEntry(displaced), before, identity: true) else { throw fail("An external write raced Apply; its actual bytes are retained for recovery", operation.path) }
                }
                try check("\(purpose).beforeVerified")
                let actual = try source.fileEntry(operation.path)
                guard same(actual, operation.after) else { throw fail("Post-mutation verification failed; recovery required", operation.path) }
                // Store actual resulting identity, so Undo catches later replacement even with identical content.
                journal.operations[index].after = actual
                journal.operations[index].step = "verified"; try writeJournal(journal, root)
                try check("\(purpose).afterVerified")
            }
            try check("\(purpose).beforeCommit")
            for operation in journal.operations {
                guard same(try source.fileEntry(operation.path), operation.after, identity: true) else { throw fail("Original changed before transaction commit", operation.path) }
            }
            if purpose == "apply" {
                let receipt = ApplyReceipt(sessionID: loaded.id, reviewID: reviewID, journalID: id, operations: journal.operations)
                try DurableJSON.write(receipt, to: root, path: "receipt.json")
            }
            journal.status = "committed"; try writeJournal(journal, root)
            try check("\(purpose).afterCommit")
            if purpose == "undo" { try publishUndoGuards(journal, root: root) }
            try coordination.release(owner: owner)
            try check("\(purpose).afterRelease")
            record.state = purpose == "apply" ? .applied : .editing
            record.lastMessage = purpose == "apply" ? "Selected reviewed files applied and verified. Retained recovery images support guarded Undo." : "Undo completed. The draft remains available; review again before a new Apply."
            try save(record, root); return record
        } catch {
            record.state = .recoveryNeeded; record.lastMessage = error.localizedDescription
            try? save(record, root); throw error
        }
    }

    private func session(_ id: UUID) throws -> (SafeDirectory, SessionRecord, SourceBinding) {
        try store.validate()
        let root = try SafeDirectory(store.url.appendingPathComponent(id.uuidString))
        let binding = try DurableJSON.read(SourceBinding.self, from: root, path: "binding.json")
        var record = try DurableJSON.read(SessionRecord.self, from: root, path: "session.json")
        guard record.id == id, binding.sessionID == id, binding.sessionIdentity == root.identity, record.sourceDevice == binding.identity.device, record.sourceInode == binding.identity.inode else { throw fail("Session identity does not match its pinned storage", id.uuidString) }
        let source = try SafePath.canonical(binding.source)
        try SafePath.validateSource(source); try SafePath.disjoint(source, store.url)
        guard source == binding.source, record.sourceURL == source else { throw fail("Source binding was changed or is malformed", id.uuidString) }
        // Never use sessionURL or snapshotURL from persisted JSON to perform file operations.
        record.sessionURL = root.url; record.sourceURL = source
        return (root, record, binding)
    }
    private func sourceRoot(_ binding: SourceBinding) throws -> SafeDirectory {
        let root = try SafeDirectory(binding.source)
        guard root.identity == binding.identity, root.device == store.device, root.ancestorIdentities == binding.sourceAncestors else { throw fail("Original root or an ancestor is missing or was replaced", binding.source.path) }
        return root
    }
    private func save(_ record: SessionRecord, _ root: SafeDirectory) throws { try DurableJSON.write(record, to: root, path: "session.json") }
    private func reservationOwner(sessionID: UUID, transactionID: UUID) -> ReservationOwner {
        ReservationOwner(sessionID: sessionID, transactionID: transactionID, storeURL: store.url, storeIdentity: store.identity)
    }
    private func check(_ point: String) throws { try fault?(point) }
    private func baselineTree(_ root: SafeDirectory, _ record: SessionRecord) throws -> CapturedTree {
        var tree = try DurableJSON.read(CapturedTree.self, from: root, path: "baseline.json")
        try tree.validatePaths()
        let baseline = try SafeDirectory(record.baselineURL)
        guard tree.equivalent(to: try TreeCapture.scan(baseline), exclusions: false) else { throw fail("Baseline bytes or metadata were changed; refusing to trust them", baseline.url.path) }
        // Guard identities change only after our own committed Undo restored the starting bytes.
        // Keep the original baseline manifest/bytes intact and prove every override from its undo journal.
        if try root.info("baseline-guards.json") != nil {
            let guards = try DurableJSON.read(BaselineGuards.self, from: root, path: "baseline-guards.json")
            var journals: [UUID: MutationJournal] = [:]
            func committedUndo(_ id: UUID) throws -> MutationJournal {
                if let value = journals[id] { return value }
                let value = try DurableJSON.read(MutationJournal.self, from: root, path: "transactions/\(id.uuidString)/journal.json")
                guard value.id == id, value.sessionID == record.id, value.purpose == "undo", value.status == "committed" else { throw fail("Baseline guard has no committed Undo provenance", record.name) }
                journals[id] = value; return value
            }
            for (path, value) in guards.files {
                try SafePath.allowed(path)
                let journal = try committedUndo(value.undoJournalID)
                guard let restored = journal.operations.first(where: { $0.path == path })?.after, restored.sameContent(as: tree.files[path]), NodeIdentity(device: restored.device, inode: restored.inode) == value.identity else { throw fail("Baseline file guard was changed", path) }
                tree.files[path]?.device = value.identity.device; tree.files[path]?.inode = value.identity.inode
            }
            for (path, value) in guards.directories {
                try SafePath.allowed(path)
                let journal = try committedUndo(value.undoJournalID)
                guard journal.operations.contains(where: { $0.parentPins[path] == value.identity }) else { throw fail("Baseline directory guard was changed", path) }
                tree.directoryIdentities[path] = value.identity
            }
        }
        return tree
    }
    private func publishUndoGuards(_ journal: MutationJournal, root: SafeDirectory) throws {
        var guards = try root.info("baseline-guards.json") == nil ? BaselineGuards() : DurableJSON.read(BaselineGuards.self, from: root, path: "baseline-guards.json")
        for operation in journal.operations {
            if let after = operation.after { guards.files[operation.path] = BaselineGuard(identity: NodeIdentity(device: after.device, inode: after.inode), undoJournalID: journal.id) }
            else { guards.files.removeValue(forKey: operation.path) }
            for (path, identity) in operation.parentPins { guards.directories[path] = BaselineGuard(identity: identity, undoJournalID: journal.id) }
        }
        try DurableJSON.write(guards, to: root, path: "baseline-guards.json")
    }
    private func validatedReview(_ root: SafeDirectory, _ record: SessionRecord) throws -> (ReviewRecord, CapturedTree, SafeDirectory) {
        var review = try DurableJSON.read(ReviewRecord.self, from: root, path: "review.json")
        guard review.sessionID == record.id else { throw fail("Review belongs to another session", record.name) }
        let path = "reviews/\(review.id.uuidString)"
        let tree = try DurableJSON.read(CapturedTree.self, from: root, path: path + ".manifest.json")
        try tree.validatePaths()
        let snapshot = try SafeDirectory(root.url.appendingPathComponent(path))
        guard tree.equivalent(to: try TreeCapture.scan(snapshot), exclusions: false), review.draftManifest == tree.files else { throw fail("Sealed review was changed or damaged; create a fresh review", record.name) }
        var seen = Set<String>()
        let baseline = try baselineTree(root, record)
        for change in review.changes {
            try SafePath.allowed(change.path)
            guard seen.insert(change.path).inserted, same(change.draft, tree.files[change.path]), same(change.baseline, baseline.files[change.path]) else { throw fail("Malformed review changeset or baseline observation", change.path) }
            if change.canApply {
                guard !same(change.baseline, change.draft), same(change.baseline, change.current, identity: true) else { throw fail("Conflicted review was relabeled as applicable", change.path) }
                let expected: ChangeKind = change.baseline == nil ? .added : (change.draft == nil ? .removed : .edited)
                guard change.kind == expected else { throw fail("Review change kind disagrees with baseline and sealed bytes", change.path) }
            }
        }
        review.snapshotURL = snapshot.url
        return (review, tree, snapshot)
    }
    private func requireNoPending(_ root: SafeDirectory) throws {
        if let journal = try readJournal(root), journal.status == "active" { throw fail("Recover the unfinished transaction first", root.url.path) }
    }
    private func readJournal(_ root: SafeDirectory) throws -> MutationJournal? {
        guard try root.info("journal.json") != nil else { return nil }
        let pointer = try DurableJSON.read(MutationJournal.self, from: root, path: "journal.json")
        // The transaction journal is durable first. The pointer can legitimately lag after a crash,
        // but can never advance a transaction to committed by itself.
        let actual = try DurableJSON.read(MutationJournal.self, from: root, path: "transactions/\(pointer.id.uuidString)/journal.json")
        guard actual.id == pointer.id, actual.sessionID == pointer.sessionID, actual.reviewID == pointer.reviewID, actual.purpose == pointer.purpose, actual.operations.map(\.path) == pointer.operations.map(\.path) else { throw fail("Journal pointer disagrees with its durable transaction", root.url.path) }
        guard pointer.status == actual.status || pointer.status == "active" else { throw fail("Journal pointer claims completion ahead of its durable transaction; all versions retained", root.url.path) }
        return actual
    }
    private func writeJournal(_ journal: MutationJournal, _ root: SafeDirectory) throws {
        try DurableJSON.write(journal, to: root, path: "transactions/\(journal.id.uuidString)/journal.json")
        try DurableJSON.write(journal, to: root, path: "journal.json")
    }
    private func validateJournal(_ journal: MutationJournal, root: SafeDirectory, record: SessionRecord) throws {
        guard journal.version == 1, journal.sessionID == record.id, ["apply", "undo"].contains(journal.purpose), ["active", "committed", "recovered"].contains(journal.status), journal.originalState == (journal.purpose == "apply" ? .editing : .applied), !journal.operations.isEmpty else { throw fail("Journal structure is invalid", record.name) }
        let transaction = try SafeDirectory(root.url.appendingPathComponent("transactions/\(journal.id.uuidString)"))
        let stored = try DurableJSON.read(MutationJournal.self, from: transaction, path: "journal.json")
        guard stored.id == journal.id, stored.sessionID == journal.sessionID, stored.reviewID == journal.reviewID, stored.purpose == journal.purpose, stored.operations.map(\.path) == journal.operations.map(\.path) else { throw fail("Journal pointer disagrees with its transaction", record.name) }
        let (review, _, _) = try validatedReview(root, record)
        guard review.id == journal.reviewID else { throw fail("Journal review is no longer available", record.name) }
        var seen = Set<String>()
        for operation in journal.operations {
            try SafePath.allowed(operation.path)
            let expectedParentPaths = Set(try parentPaths(operation.path))
            guard Set(operation.parentPins.keys).isSubset(of: expectedParentPaths) else { throw fail("Journal contains unsafe ancestor identity paths", operation.path) }
            guard seen.insert(operation.path).inserted, ["staged", "attempted", "verified", "recovered"].contains(operation.step), operation.before != nil || operation.after != nil, let change = review.changes.first(where: { $0.path == operation.path }), change.canApply else { throw fail("Unsafe journal operation", operation.path) }
            let expectedBefore = journal.purpose == "apply" ? change.baseline : change.draft
            let expectedAfter = journal.purpose == "apply" ? change.draft : change.baseline
            guard same(operation.before, expectedBefore), same(operation.after, expectedAfter) else { throw fail("Journal states disagree with sealed review", operation.path) }
            if let before = operation.before {
                guard before.sameContent(as: try transaction.fileEntry("before/\(operation.path)")) else { throw fail("Verified recovery image was changed or is missing", operation.path) }
            }
        }
    }
    private func validateReceipt(_ receipt: ApplyReceipt, root: SafeDirectory, record: SessionRecord) throws {
        guard receipt.sessionID == record.id else { throw fail("Receipt belongs to another session", record.name) }
        let applied = try DurableJSON.read(MutationJournal.self, from: root, path: "transactions/\(receipt.journalID.uuidString)/journal.json")
        try validateJournal(applied, root: root, record: record)
        guard applied.status == "committed", applied.purpose == "apply", applied.reviewID == receipt.reviewID, applied.operations.count == receipt.operations.count else { throw fail("Apply receipt does not match its committed journal", record.name) }
        for (a, b) in zip(applied.operations, receipt.operations) {
            guard a.path == b.path, same(a.before, b.before, identity: true), same(a.after, b.after, identity: true) else { throw fail("Apply receipt was changed", b.path) }
        }
    }
    private func same(_ a: FileEntry?, _ b: FileEntry?, identity: Bool = false) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.sameContent(as: b) && (!identity || (a.device == b.device && a.inode == b.inode))
        default: return false
        }
    }
    private func parentPaths(_ path: String) throws -> [String] {
        let parts = try SafePath.components(path)
        return parts.dropLast().indices.map { parts[...$0].joined(separator: "/") }
    }
    private func threeWay(baseline: CapturedTree, current: CapturedTree?, draft: CapturedTree, sourceMessage: String?) -> [FileChange] {
        let paths = Set(baseline.files.keys).union(current?.files.keys.map { $0 } ?? []).union(draft.files.keys)
        var folded: [String: Set<String>] = [:]
        for path in Set(baseline.files.keys).union(draft.files.keys).union(baseline.directories).union(draft.directories) { folded[SafePath.key(path), default: []].insert(path) }
        return paths.sorted().compactMap { path in
            let base = baseline.files[path], original = current?.files[path], edited = draft.files[path]
            let parentSame = (try? parentPaths(path).allSatisfy { baseline.directoryIdentities[$0] == current?.directoryIdentities[$0] }) ?? false
            let draftSame = same(base, edited), originalSame = same(base, original, identity: true) && parentSame
            var kind: ChangeKind
            var message: String?
            if folded[SafePath.key(path), default: []].count > 1 { kind = .conflict; message = "Case-only or Unicode-equivalent rename requires manual handling." }
            else if current == nil { kind = .conflict; message = sourceMessage ?? "Original unavailable." }
            else if draftSame && originalSame { return nil }
            else if draftSame { kind = .sourceOnly }
            else if same(edited, original) { kind = .identical }
            else if !originalSame { kind = .conflict; message = "Original changed since the baseline. Keep the current original or export the sealed draft." }
            else if base == nil { kind = .added }
            else if edited == nil { kind = .removed }
            else { kind = .edited }
            return FileChange(path: path, kind: kind, baseline: base, current: original, draft: edited, message: message)
        }
    }
}
