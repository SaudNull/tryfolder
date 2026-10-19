import Foundation
import Darwin

/// One durable per-user coordination directory serves every store/process.
/// Tests and probe subprocesses must share TRYFOLDER_COORDINATION_ROOT; never vary it by store.
/// Unresolved reservations are never expired or removed merely because a store/source is unavailable.
final class MutationLock {
    private let fd: Int32
    let coordination: SafeDirectory
    init() throws {
        let configured = ProcessInfo.processInfo.environment["TRYFOLDER_COORDINATION_ROOT"]
        let location: URL
        if let configured {
            guard configured.hasPrefix("/"), !configured.utf8.contains(0) else { throw fail("TRYFOLDER_COORDINATION_ROOT must be an absolute local directory", configured) }
            location = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            location = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TryFolder/Coordination", isDirectory: true)
        }
        let localCoordination = try SafeDirectory(location, create: true)
        let name = localCoordination.url.appendingPathComponent("mutation.lock").path
        let localFD = openat(localCoordination.fd, "mutation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard localFD >= 0 else { throw posix("Open durable global TryFolder lock", name) }
        // Keep all descriptor ownership local until every throwing initialization step succeeds.
        // Swift deinitializes a fully initialized instance even when its initializer later throws.
        var transferred = false
        var acquired = false
        defer {
            if !transferred {
                if acquired { flock(localFD, LOCK_UN) }
                Darwin.close(localFD)
            }
        }
        var value = stat()
        guard fstat(localFD, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1, value.st_uid == getuid() else { throw fail("Unsafe global lock file", name) }
        guard flock(localFD, LOCK_EX | LOCK_NB) == 0 else { throw fail("Another TryFolder operation is running; retry when it finishes", name) }
        acquired = true
        guard fstat(localCoordination.fd, &value) == 0, value.st_uid == getuid() else { throw fail("Coordination storage must belong to this user", location.path) }
        guard fchmod(localCoordination.fd, 0o700) == 0 else { throw posix("Protect durable coordination storage", location.path) }
        if try localCoordination.info("coordination.json") == nil {
            if try localCoordination.info("reservations.json") != nil {
                let previous = try DurableJSON.read(SourceReservations.self, from: localCoordination, path: "reservations.json")
                guard previous.version == 1, previous.reservations.isEmpty else { throw fail("Uninitialized coordination storage contains unresolved reservations; refusing to reset", location.path) }
            } else { try DurableJSON.write(SourceReservations(), to: localCoordination, path: "reservations.json") }
            try DurableJSON.write(CoordinationMarker(identity: localCoordination.identity), to: localCoordination, path: "coordination.json")
        } else {
            let marker = try DurableJSON.read(CoordinationMarker.self, from: localCoordination, path: "coordination.json")
            guard marker.version == 1, marker.identity == localCoordination.identity else { throw fail("Coordination storage identity changed", location.path) }
            guard try localCoordination.info("reservations.json") != nil else { throw fail("Durable reservation registry is missing; restore it before mutating any source", location.path) }
        }
        _ = try Self.readRegistry(localCoordination)
        self.coordination = localCoordination
        self.fd = localFD
        transferred = true
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }

    func checkAvailable(source: SafeDirectory, owner: ReservationOwner? = nil) throws {
        try checkAvailable(sourceURL: source.url, sourceIdentity: source.identity, sourceAncestors: source.ancestorIdentities, owner: owner)
    }
    func checkAvailable(sourceURL: URL, sourceIdentity: NodeIdentity, sourceAncestors: [NodeIdentity], owner: ReservationOwner? = nil) throws {
        for reservation in try registry().reservations {
            if let owner, reservation.owner == owner { continue }
            let lexicalOverlap = SafePath.isInside(sourceURL, reservation.sourceURL) || SafePath.isInside(reservation.sourceURL, sourceURL)
            let identityOverlap = sourceAncestors.contains(reservation.sourceIdentity) || reservation.sourceAncestors.contains(sourceIdentity)
            if lexicalOverlap || identityOverlap {
                throw fail("An unresolved \(reservation.purpose) in session \(reservation.owner.sessionID.uuidString) reserves an overlapping source. Recover that owning session first; all versions remain retained", sourceURL.path)
            }
        }
    }
    func reserve(source: SafeDirectory, owner: ReservationOwner, purpose: String) throws {
        try checkAvailable(source: source, owner: owner)
        var current = try registry()
        if let existing = current.reservations.first(where: { $0.owner == owner }) {
            guard existing.sourceIdentity == source.identity, existing.sourceURL == source.url, existing.sourceAncestors == source.ancestorIdentities, existing.purpose == purpose else { throw fail("Existing owner reservation disagrees with its source binding", source.url.path) }
            return
        }
        current.reservations.append(SourceReservation(owner: owner, sourceURL: source.url, sourceIdentity: source.identity, sourceAncestors: source.ancestorIdentities, purpose: purpose))
        try DurableJSON.write(current, to: coordination, path: "reservations.json")
    }
    func release(owner: ReservationOwner) throws {
        var current = try registry()
        current.reservations.removeAll { $0.owner == owner }
        try DurableJSON.write(current, to: coordination, path: "reservations.json")
    }
    private func registry() throws -> SourceReservations {
        try Self.readRegistry(coordination)
    }
    private static func readRegistry(_ coordination: SafeDirectory) throws -> SourceReservations {
        let value = try DurableJSON.read(SourceReservations.self, from: coordination, path: "reservations.json")
        guard value.version == 1 else { throw fail("Unsupported reservation registry version", coordination.url.path) }
        var owners = Set<ReservationOwner>()
        for item in value.reservations {
            let canonical = try SafePath.canonical(item.sourceURL)
            let store = try SafePath.canonical(item.owner.storeURL)
            guard canonical == item.sourceURL, store == item.owner.storeURL, item.sourceAncestors.last == item.sourceIdentity, item.sourceIdentity.device != 0, item.sourceIdentity.inode != 0, item.owner.storeIdentity.device != 0, item.owner.storeIdentity.inode != 0, ["apply", "undo"].contains(item.purpose), owners.insert(item.owner).inserted else { throw fail("Malformed durable reservation; refusing to prune or bypass it", coordination.url.path) }
        }
        return value
    }
}

struct CoordinationMarker: Codable { var version = 1; var identity: NodeIdentity }
struct ReservationOwner: Codable, Equatable, Hashable {
    var sessionID: UUID
    var transactionID: UUID
    var storeURL: URL
    var storeIdentity: NodeIdentity
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.sessionID == rhs.sessionID && lhs.transactionID == rhs.transactionID && lhs.storeIdentity == rhs.storeIdentity }
    func hash(into hasher: inout Hasher) { hasher.combine(sessionID); hasher.combine(transactionID); hasher.combine(storeIdentity) }
}
struct SourceReservation: Codable {
    var owner: ReservationOwner
    var sourceURL: URL
    var sourceIdentity: NodeIdentity
    var sourceAncestors: [NodeIdentity]
    var purpose: String
}
struct SourceReservations: Codable { var version = 1; var reservations: [SourceReservation] = [] }

enum DurableJSON {
    static func read<T: Decodable>(_ type: T.Type, from root: SafeDirectory, path: String) throws -> T {
        let (parent, name) = try root.parent(path); defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posix("Open record", path) }
        defer { Darwin.close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1, value.st_size >= 0, value.st_size <= 64 * 1024 * 1024 else { throw fail("Record is unsafe or exceeds supported size", path) }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posix("Read record", path) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 64 * 1024 * 1024 else { throw fail("Record grew while reading", path) }
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw fail("Record is malformed (\(error.localizedDescription))", path) }
    }
    static func write<T: Encodable>(_ record: T, to root: SafeDirectory, path: String) throws {
        try root.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let (parent, name) = try root.parent(path, create: true); defer { Darwin.close(parent) }
        let temporary = ".record-\(UUID().uuidString)"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("Create durable record", path) }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw posix("Write durable record", path) }
                guard count > 0 else { throw fail("Short record write", path) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw posix("Sync durable record", path) }
        // rename replaces only this application-owned JSON directory entry, never user file content.
        guard renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw posix("Commit durable record", path) }
    }
}

struct CapturedTree: Codable {
    var files: [String: FileEntry]
    var directories: [String]
    var excluded: [ExcludedItem]
    var directoryIdentities: [String: NodeIdentity] = [:]

    func equivalent(to other: CapturedTree, identities: Bool = false, exclusions: Bool = true) -> Bool {
        guard directories == other.directories, (!exclusions || excluded == other.excluded), files.keys.sorted() == other.files.keys.sorted(), (!identities || directoryIdentities == other.directoryIdentities) else { return false }
        return files.allSatisfy { path, entry in
            guard entry.sameContent(as: other.files[path]) else { return false }
            return !identities || (entry.device == other.files[path]!.device && entry.inode == other.files[path]!.inode)
        }
    }
    func validatePaths() throws {
        var keys: [String: String] = [:]
        for path in files.keys.sorted() + directories {
            try SafePath.allowed(path)
            let normalized = SafePath.key(path)
            if let previous = keys[normalized], previous != path { throw fail("Ambiguous manifest path", path) }
            keys[normalized] = path
        }
        for (path, value) in files {
            guard value.path == path, value.kind == "file", value.fingerprint.count == 64 else { throw fail("Malformed manifest entry", path) }
        }
        for item in excluded { _ = try SafePath.components(item.path) }
    }
}

enum TreeCapture {
    static func scan(_ root: SafeDirectory) throws -> CapturedTree {
        try root.validate()
        var files: [String: FileEntry] = [:]; var directories: [String] = []; var excluded: [ExcludedItem] = []; var directoryIdentities: [String: NodeIdentity] = [:]
        func visit(_ prefix: String?) throws {
            for name in try root.names(prefix) {
                let path = prefix.map { $0 + "/" + name } ?? name
                _ = try SafePath.components(path)
                guard name != ".tryfolder-store" else { throw fail("Nested TryFolder managed storage is not ordinary source content", path) }
                if SafePath.excludedNames.contains(SafePath.key(name)) {
                    let reason = SafePath.key(name) == ".ds_store" ? "Finder metadata file excluded; never copied, applied or deleted." : "Generated/dependency/version-control item excluded; never traversed or deleted."
                    excluded.append(ExcludedItem(path: path, reason: reason)); continue
                }
                try SafePath.allowed(path)
                guard let value = try root.info(path), UInt64(value.st_dev) == root.device else { throw fail("Item disappeared or crossed a volume during capture", path) }
                if (value.st_mode & S_IFMT) == S_IFDIR {
                    guard value.st_flags == 0 else { throw fail("Directory flags are unsupported", path) }
                    let (parent, leaf) = try root.parent(path); defer { Darwin.close(parent) }
                    let fd = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw posix("Open directory", path) }
                    defer { Darwin.close(fd) }
                    try FileMetadata.rejectACL(fd, path: path)
                    directories.append(path); directoryIdentities[path] = NodeIdentity(value); try visit(path)
                    var after = stat()
                    guard fstat(fd, &after) == 0, NodeIdentity(after) == NodeIdentity(value) else { throw fail("Directory changed during scan", path) }
                } else if (value.st_mode & S_IFMT) == S_IFREG {
                    files[path] = try root.fileEntry(path)
                } else { throw fail("Symlinks, special files and cloud placeholders are unsupported", path) }
            }
        }
        try visit(nil); try root.validate()
        return CapturedTree(files: files, directories: directories.sorted(), excluded: excluded.sorted { $0.path < $1.path }, directoryIdentities: directoryIdentities)
    }
    static func copy(_ tree: CapturedTree, from source: SafeDirectory, to target: SafeDirectory) throws {
        try tree.validatePaths()
        for path in tree.directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) { try target.makeDirectory(path) }
        for path in tree.files.keys.sorted() { try source.copyFile(path, to: target) }
        guard tree.equivalent(to: try scan(target), exclusions: false) else { throw fail("Captured bytes or metadata did not verify", target.url.path) }
    }
}

struct SourceBinding: Codable {
    var sessionID: UUID
    var source: URL
    var identity: NodeIdentity
    var sessionIdentity: NodeIdentity
    var sourceAncestors: [NodeIdentity]
}
struct StoreMarker: Codable {
    var app = "TryFolder"
    var version = 1
    var identity: NodeIdentity
}

struct JournalOperation: Codable {
    var path: String
    var before: FileEntry?
    var after: FileEntry?
    var step: String // staged, attempted, verified, recovered
    var parentPins: [String: NodeIdentity] = [:]
}
struct MutationJournal: Codable {
    var version = 1
    var id: UUID
    var sessionID: UUID
    var reviewID: UUID
    var purpose: String // apply or undo
    var originalState: SessionState
    var status: String // active, committed, recovered
    var operations: [JournalOperation]
}
struct ApplyReceipt: Codable {
    var sessionID: UUID
    var reviewID: UUID
    var journalID: UUID
    var operations: [JournalOperation]
}
struct BaselineGuard: Codable {
    var identity: NodeIdentity
    var undoJournalID: UUID
}
struct BaselineGuards: Codable {
    var files: [String: BaselineGuard] = [:]
    var directories: [String: BaselineGuard] = [:]
}
