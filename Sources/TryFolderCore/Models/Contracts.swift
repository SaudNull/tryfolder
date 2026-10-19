import Foundation

public enum SessionState: String, Codable, Sendable {
    case preparing, editing, reviewing, readyToApply, applying, applied, conflict, interrupted, discarded, recoveryNeeded
}
public enum ChangeKind: String, Codable, Sendable, CaseIterable { case added, edited, removed, sourceOnly, identical, conflict }
public struct ExcludedItem: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var reason: String
    public var id: String { path }
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}
public struct FileEntry: Codable, Sendable, Equatable {
    public var path: String
    public var kind: String
    public var size: UInt64
    public var fingerprint: String
    public var metadataFingerprint: String
    public var device: UInt64
    public var inode: UInt64
    public var mode: UInt32
    public var modifiedAt: Date
    public init(path: String, kind: String = "file", size: UInt64, fingerprint: String, metadataFingerprint: String = "", device: UInt64, inode: UInt64, mode: UInt32, modifiedAt: Date) {
        self.path = path; self.kind = kind; self.size = size; self.fingerprint = fingerprint; self.metadataFingerprint = metadataFingerprint; self.device = device; self.inode = inode; self.mode = mode; self.modifiedAt = modifiedAt
    }
    public func sameContent(as other: FileEntry?) -> Bool {
        guard let other else { return false }
        return kind == other.kind && fingerprint == other.fingerprint && metadataFingerprint == other.metadataFingerprint && mode == other.mode
    }
}
public struct SessionRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceURL: URL
    public var sessionURL: URL
    public var sourceDevice: UInt64
    public var sourceInode: UInt64
    public var createdAt: Date
    public var state: SessionState
    public var excluded: [ExcludedItem]
    public var lastMessage: String?
    public var baselineURL: URL { sessionURL.appendingPathComponent("baseline", isDirectory: true) }
    public var draftURL: URL { sessionURL.appendingPathComponent("draft", isDirectory: true) }
    public init(id: UUID, name: String, sourceURL: URL, sessionURL: URL, sourceDevice: UInt64, sourceInode: UInt64, createdAt: Date = Date(), state: SessionState = .preparing, excluded: [ExcludedItem] = [], lastMessage: String? = nil) {
        self.id = id; self.name = name; self.sourceURL = sourceURL; self.sessionURL = sessionURL; self.sourceDevice = sourceDevice; self.sourceInode = sourceInode; self.createdAt = createdAt; self.state = state; self.excluded = excluded; self.lastMessage = lastMessage
    }
}
public struct FileChange: Codable, Sendable, Identifiable {
    public var path: String
    public var kind: ChangeKind
    public var baseline: FileEntry?
    public var current: FileEntry?
    public var draft: FileEntry?
    public var message: String?
    public var id: String { path }
    public var canApply: Bool { kind == .added || kind == .edited || kind == .removed }
    public init(path: String, kind: ChangeKind, baseline: FileEntry?, current: FileEntry?, draft: FileEntry?, message: String? = nil) {
        self.path = path; self.kind = kind; self.baseline = baseline; self.current = current; self.draft = draft; self.message = message
    }
}
public struct ReviewRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var snapshotURL: URL
    public var changes: [FileChange]
    public var excluded: [ExcludedItem]
    public var sourceUnchanged: Bool
    public var sourceAvailable: Bool
    public var draftManifest: [String: FileEntry]
    public init(id: UUID, sessionID: UUID, createdAt: Date = Date(), snapshotURL: URL, changes: [FileChange], excluded: [ExcludedItem] = [], sourceUnchanged: Bool, sourceAvailable: Bool = true, draftManifest: [String: FileEntry]) {
        self.id = id; self.sessionID = sessionID; self.createdAt = createdAt; self.snapshotURL = snapshotURL; self.changes = changes; self.excluded = excluded; self.sourceUnchanged = sourceUnchanged; self.sourceAvailable = sourceAvailable; self.draftManifest = draftManifest
    }
}
public enum ReleaseCapabilities {
    // Enabled only by root after mandatory mutation/recovery gates pass.
    public static let applyAndUndo = true
    public static let version = "0.1.0"
}
