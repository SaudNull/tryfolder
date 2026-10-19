import Foundation
import CryptoKit
import Darwin

public struct TryFolderError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func fail(_ message: String, _ path: String) -> TryFolderError { TryFolderError("\(message): \(path)") }
func posix(_ operation: String, _ path: String) -> TryFolderError {
    let code = errno
    return fail("\(operation) failed (\(String(cString: strerror(code))))", path)
}

struct NodeIdentity: Codable, Equatable, Hashable {
    var device: UInt64
    var inode: UInt64
    init(_ value: stat) { device = UInt64(value.st_dev); inode = UInt64(value.st_ino) }
    init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

enum SafePath {
    static let excludedNames: Set<String> = [".ds_store", ".git", "node_modules", ".build", "build", "dist", "deriveddata", ".venv", "venv", "__pycache__"]
    static let forbiddenExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary", "library", "db", "sqlite", "sqlite3", "db-shm", "db-wal"]

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw fail("Unsafe relative path", path)
        }
        return parts
    }
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", !url.path.utf8.contains(0) else { throw fail("A local file URL is required", url.absoluteString) }
        var path = url.standardizedFileURL.path
        // macOS provides these fixed system aliases. All user-controlled components still use O_NOFOLLOW.
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        guard path.hasPrefix("/"), path != "/" else { throw fail("The filesystem root is unsupported", path) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.path.precomposedStringWithCanonicalMapping.lowercased()
        let p = parent.path.precomposedStringWithCanonicalMapping.lowercased()
        return c == p || c.hasPrefix(p + "/")
    }
    static func disjoint(_ a: URL, _ b: URL) throws {
        guard !isInside(a, b), !isInside(b, a) else { throw fail("Source, output and managed storage must be disjoint", a.path) }
    }
    static func validateSource(_ url: URL) throws {
        let path = url.path
        let policyPath = key(path)
        let exact = ["/Applications", "/System", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/usr", "/bin", "/sbin", "/dev", "/etc", NSHomeDirectory()]
        guard !exact.map(key).contains(policyPath) else { throw fail("Select an ordinary folder below this protected root", path) }
        let banned = ["/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/dev", "/private/etc", NSHomeDirectory() + "/Library"]
        guard !banned.map(key).contains(where: { policyPath == $0 || policyPath.hasPrefix($0 + "/") }) else { throw fail("Protected or cloud-managed location is unsupported", path) }
        for part in path.split(separator: "/").map(String.init) {
            if excludedNames.contains(key(part)) || ["cloudstorage", "mobile documents", ".trash", ".ssh", ".aws", ".gnupg", ".codex"].contains(key(part)) || forbiddenExtensions.contains(URL(fileURLWithPath: part).pathExtension.lowercased()) {
                throw fail("Excluded, cloud-managed or application data location is unsupported", path)
            }
        }
    }
    static func allowed(_ relative: String) throws {
        let parts = try components(relative)
        guard !parts.contains(where: { excludedNames.contains(key($0)) || ["cloudstorage", "mobile documents", ".ssh", ".aws", ".gnupg", ".codex"].contains(key($0)) || forbiddenExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) else {
            throw fail("Excluded or unsupported path", relative)
        }
    }
}

/// Every operation beneath a content root is descriptor-relative. This object also pins its absolute ancestors.
final class SafeDirectory {
    let fd: Int32
    let url: URL
    let identity: NodeIdentity
    private let ancestors: [NodeIdentity]
    var ancestorIdentities: [NodeIdentity] { ancestors }
    var device: UInt64 { identity.device }

    init(_ input: URL, create: Bool = false, mode: mode_t = 0o700) throws {
        let url = try SafePath.canonical(input)
        var cursor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw posix("Open root", "/") }
        var pins: [NodeIdentity] = []
        do {
            for part in url.path.split(separator: "/").map(String.init) {
                var next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(cursor, part, mode) == 0 || errno == EEXIST else { throw posix("Create directory", url.path) }
                    guard fsync(cursor) == 0 else { throw posix("Sync parent directory", url.path) }
                    next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posix("Open directory without following links", url.path) }
                Darwin.close(cursor); cursor = next
                var info = stat()
                guard fstat(cursor, &info) == 0 else { throw posix("Inspect directory", url.path) }
                pins.append(NodeIdentity(info))
            }
            var volume = statfs()
            guard fstatfs(cursor, &volume) == 0, (volume.f_flags & UInt32(MNT_LOCAL)) != 0 else { throw fail("Only a mounted local volume is supported", url.path) }
            self.fd = cursor; self.url = url; self.ancestors = pins; self.identity = pins.last!
        } catch { Darwin.close(cursor); throw error }
    }
    deinit { Darwin.close(fd) }

    func validate() throws {
        let current = try SafeDirectory(url)
        guard current.ancestors == ancestors else { throw fail("Root or ancestor was replaced; operation stopped", url.path) }
    }
    func sameVolume(as other: SafeDirectory) throws {
        guard device == other.device else { throw fail("Source and storage must use the same local volume", other.url.path) }
    }
    func requireDisjoint(from other: SafeDirectory) throws {
        // APFS firmlinks and case aliases can give different absolute paths to the same directory.
        guard !ancestorIdentities.contains(other.identity), !other.ancestorIdentities.contains(identity) else { throw fail("Managed storage and source overlap by filesystem identity", other.url.path) }
    }
    func rejectManagedAncestor() throws {
        var cursor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw posix("Open source ancestry", url.path) }
        defer { Darwin.close(cursor) }
        for part in url.path.split(separator: "/").map(String.init) {
            let next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posix("Validate managed-tree boundary", url.path) }
            Darwin.close(cursor); cursor = next
            var value = stat()
            if fstatat(cursor, ".tryfolder-store", &value, AT_SYMLINK_NOFOLLOW) == 0 { throw fail("A TryFolder managed storage ancestor cannot be selected or exported into", url.path) }
            guard errno == ENOENT else { throw posix("Inspect managed-tree marker", url.path) }
        }
    }
    func info(_ relative: String) throws -> stat? {
        let (parent, name) = try parent(relative)
        defer { Darwin.close(parent) }
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) < 0 {
            if errno == ENOENT { return nil }
            throw posix("Inspect item", relative)
        }
        return value
    }
    func parent(_ relative: String, create: Bool = false, expectedPins: [String: NodeIdentity]? = nil) throws -> (Int32, String) {
        let components = try SafePath.components(relative)
        var cursor = dup(fd)
        guard cursor >= 0 else { throw posix("Open parent", relative) }
        do {
            var traversed: [String] = []
            for part in components.dropLast() {
                traversed.append(part)
                var next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(cursor, part, 0o755) == 0 || errno == EEXIST else { throw posix("Create parent", relative) }
                    guard fsync(cursor) == 0 else { throw posix("Sync parent", relative) }
                    next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posix("Open parent without following links", relative) }
                var value = stat()
                guard fstat(next, &value) == 0, UInt64(value.st_dev) == device else { Darwin.close(next); throw fail("Nested volume or replaced ancestor", relative) }
                if let expectedPins {
                    guard expectedPins[traversed.joined(separator: "/")] == NodeIdentity(value) else { Darwin.close(next); throw fail("Inner ancestor was replaced after validation", relative) }
                }
                Darwin.close(cursor); cursor = next
            }
            return (cursor, components.last!)
        } catch { Darwin.close(cursor); throw error }
    }
    func ancestorPins(_ relative: String) throws -> [String: NodeIdentity] {
        let parts = try SafePath.components(relative)
        var cursor = dup(fd); defer { Darwin.close(cursor) }
        var result: [String: NodeIdentity] = [:]; var traversed: [String] = []
        for part in parts.dropLast() {
            traversed.append(part)
            let next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return result }
                throw posix("Pin inner ancestor", relative)
            }
            Darwin.close(cursor); cursor = next
            var value = stat()
            guard fstat(cursor, &value) == 0, UInt64(value.st_dev) == device else { throw fail("Inner ancestor crossed a volume", relative) }
            result[traversed.joined(separator: "/")] = NodeIdentity(value)
        }
        return result
    }
    func validateAncestors(_ relative: String, pins: [String: NodeIdentity]) throws {
        let current = try ancestorPins(relative)
        guard current == pins else { throw fail("Inner ancestor appeared, disappeared or was replaced after validation", relative) }
    }
    /// Only missing ordinary parents are created. Previously observed parents and transaction-created parents are pinned.
    func prepareParents(_ relative: String, pins: [String: NodeIdentity], created: inout [String: NodeIdentity]) throws -> [String: NodeIdentity] {
        let parts = try SafePath.components(relative)
        var cursor = dup(fd); defer { Darwin.close(cursor) }
        var result: [String: NodeIdentity] = [:]; var traversed: [String] = []
        for part in parts.dropLast() {
            traversed.append(part); let prefix = traversed.joined(separator: "/")
            var next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var made = false
            if next < 0, errno == ENOENT {
                guard pins[prefix] == nil, created[prefix] == nil else { throw fail("A pinned source ancestor disappeared", relative) }
                guard mkdirat(cursor, part, 0o755) == 0 else { throw posix("Create missing source parent", prefix) }
                guard fsync(cursor) == 0 else { throw posix("Sync source parent", prefix) }
                next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); made = true
            }
            guard next >= 0 else { throw posix("Open pinned source parent", prefix) }
            var value = stat()
            guard fstat(next, &value) == 0, UInt64(value.st_dev) == device else { Darwin.close(next); throw fail("Nested source volume", prefix) }
            let actual = NodeIdentity(value)
            if made { created[prefix] = actual }
            else { guard (pins[prefix] ?? created[prefix]) == actual else { Darwin.close(next); throw fail("Source ancestor changed during mutation", prefix) } }
            result[prefix] = actual
            Darwin.close(cursor); cursor = next
        }
        return result
    }
    func openFile(_ relative: String, flags: Int32 = O_RDONLY) throws -> Int32 {
        let (parent, name) = try parent(relative)
        defer { Darwin.close(parent) }
        let result = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard result >= 0 else { throw posix("Open regular file", relative) }
        do { _ = try FileMetadata.read(result, path: relative, device: device); return result }
        catch { Darwin.close(result); throw error }
    }
    func makeDirectory(_ relative: String) throws {
        let (parent, name) = try parent(relative, create: true)
        defer { Darwin.close(parent) }
        guard mkdirat(parent, name, 0o755) == 0 else {
            if errno == EEXIST {
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw posix("Validate directory", relative) }
                Darwin.close(child); return
            }
            throw posix("Create directory", relative)
        }
        guard fsync(parent) == 0 else { throw posix("Sync directory", relative) }
    }
    func names(_ relative: String? = nil) throws -> [String] {
        var directoryFD: Int32
        if let relative {
            let (parent, name) = try parent(relative); defer { Darwin.close(parent) }
            directoryFD = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else { directoryFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw posix("Enumerate directory", relative ?? url.path) }
        guard let stream = fdopendir(directoryFD) else { Darwin.close(directoryFD); throw posix("Enumerate directory", relative ?? url.path) }
        defer { closedir(stream) }
        var result: [String] = []; var keys = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw fail("Non-UTF8 filename is unsupported", relative ?? url.path) }
            if name == "." || name == ".." { continue }
            guard keys.insert(SafePath.key(name)).inserted else { throw fail("Ambiguous case or Unicode filename collision", name) }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else { throw posix("Read directory", relative ?? url.path) }
        return result.sorted()
    }
    func fileEntry(_ relative: String) throws -> FileEntry? {
        // Missing ancestors are an absent file, but symlinks and non-directories remain errors.
        do {
            guard let value = try info(relative) else { return nil }
            guard (value.st_mode & S_IFMT) == S_IFREG else { throw fail("Expected an ordinary regular file", relative) }
            let file = try openFile(relative); defer { Darwin.close(file) }
            return try FileMetadata.entry(file, path: relative, device: device)
        } catch {
            // Do not classify a generic POSIX failure as absence.
            if try missingParent(relative) { return nil }
            throw error
        }
    }
    private func missingParent(_ relative: String) throws -> Bool {
        let parts = try SafePath.components(relative)
        var cursor = dup(fd); defer { Darwin.close(cursor) }
        for part in parts.dropLast() {
            let next = openat(cursor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { return errno == ENOENT }
            Darwin.close(cursor); cursor = next
        }
        return false
    }
    func copyFile(_ relative: String, to target: SafeDirectory, as output: String? = nil) throws {
        let output = output ?? relative
        let input = try openFile(relative); defer { Darwin.close(input) }
        let before = try FileMetadata.read(input, path: relative, device: device)
        let (parent, name) = try target.parent(output, create: true); defer { Darwin.close(parent) }
        let destination = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw posix("Create independent file", output) }
        defer { Darwin.close(destination) }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posix("Read file", relative) }
            try buffer.withUnsafeBytes { raw in try writeAll(destination, raw.baseAddress!, count, path: output) }
        }
        try before.apply(to: destination, path: output)
        guard fsync(destination) == 0, fsync(parent) == 0 else { throw posix("Sync copied file", output) }
        let after = try FileMetadata.read(input, path: relative, device: device)
        guard before.stable(as: after) else { throw fail("File changed during capture; close its editor and retry", relative) }
        guard try FileMetadata.read(destination, path: output, device: target.device).info.st_flags == before.info.st_flags else { throw fail("Independent copy did not preserve its supported document-tracking flag", output) }
        let expected = try FileMetadata.entry(input, path: relative, device: device)
        // O_WRONLY cannot hash; reopen the target without following links and verify it.
        guard let actual = try target.fileEntry(output), expected.sameContent(as: actual) else { throw fail("Independent copy verification failed", output) }
    }
    func rename(_ relative: String, to target: SafeDirectory, as output: String, swap: Bool = false, sourcePins: [String: NodeIdentity]? = nil, targetPins: [String: NodeIdentity]? = nil) throws {
        let (a, sourceName) = try parent(relative, expectedPins: sourcePins); defer { Darwin.close(a) }
        let (b, destinationName) = try target.parent(output, create: targetPins == nil, expectedPins: targetPins); defer { Darwin.close(b) }
        try validate(); try target.validate()
        guard renameatx_np(a, sourceName, b, destinationName, UInt32(swap ? RENAME_SWAP : RENAME_EXCL)) == 0 else { throw posix("Guarded file rename", relative) }
        guard fsync(a) == 0, fsync(b) == 0 else { throw posix("Sync file mutation", relative) }
    }
}

private func writeAll(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, path: String) throws {
    var offset = 0
    while offset < count {
        let written = Darwin.write(fd, buffer.advanced(by: offset), count - offset)
        if written < 0 { if errno == EINTR { continue }; throw posix("Write file", path) }
        guard written > 0 else { throw fail("Short file write", path) }
        offset += written
    }
}

struct FileMetadata {
    let info: stat
    let attrs: [String: Data]
    static func read(_ fd: Int32, path: String, device: UInt64) throws -> FileMetadata {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posix("Read file metadata", path) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, UInt64(info.st_dev) == device else { throw fail("Symlinks, hard links, special files and nested devices are unsupported", path) }
        // TextEdit/document-based apps mark ordinary saved files UF_TRACKED (document-ID tracking).
        // Preserve it on independent copies; APFS may transfer it with pathname identity during rename,
        // so it is intentionally excluded from semantic fingerprints. All other flags remain unsupported.
        guard (info.st_flags & ~UInt32(UF_TRACKED)) == 0 else { throw fail("Filesystem flags other than ordinary document tracking are unsupported in this release", path) }
        try rejectACL(fd, path: path)
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0, count <= 1_048_576 else { throw posix("List extended attributes", path) }
        var names = [CChar](repeating: 0, count: Int(count))
        if count > 0 { guard flistxattr(fd, &names, names.count, 0) == count else { throw fail("Extended attributes changed during capture", path) } }
        let keys = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var attrs: [String: Data] = [:]; var total = 0
        for key in keys {
            guard !key.hasPrefix("com.apple.fileprovider"), !key.hasPrefix("com.apple.icloud"), key != "com.apple.decmpfs" else { throw fail("Cloud placeholder or compressed file is unsupported", path) }
            let length = fgetxattr(fd, key, nil, 0, 0, 0)
            guard length >= 0 else { throw posix("Read extended attribute", path) }
            total += Int(length)
            guard total <= 64 * 1024 * 1024 else { throw fail("Extended attributes exceed the supported 64 MiB limit", path) }
            var bytes = Data(count: Int(length))
            let actual = bytes.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
            guard actual == length else { throw fail("Extended attributes changed during capture", path) }
            attrs[key] = bytes
        }
        return FileMetadata(info: info, attrs: attrs)
    }
    static func rejectACL(_ fd: Int32, path: String) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return } // macOS represents no extended ACL as nil/ENOENT.
            throw posix("Read ACL", path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == -1 && errno == ENOENT else {
            // macOS returns -1/ENOENT for an empty ACL; any actual entry needs unsupported ACL copying.
            if result == 0 { throw fail("Files or directories with ACL entries are unsupported", path) }
            throw posix("Read ACL entry", path)
        }
    }
    func stable(as other: FileMetadata) -> Bool {
        NodeIdentity(info) == NodeIdentity(other.info) && info.st_size == other.info.st_size && info.st_mode == other.info.st_mode && info.st_flags == other.info.st_flags && info.st_mtimespec.tv_sec == other.info.st_mtimespec.tv_sec && info.st_mtimespec.tv_nsec == other.info.st_mtimespec.tv_nsec && info.st_ctimespec.tv_sec == other.info.st_ctimespec.tv_sec && info.st_ctimespec.tv_nsec == other.info.st_ctimespec.tv_nsec && attrs == other.attrs
    }
    func apply(to fd: Int32, path: String) throws {
        // New files start with no source ACL. Preserve every supported xattr including quarantine/resource forks.
        let existingCount = flistxattr(fd, nil, 0, 0)
        guard existingCount >= 0 else { throw posix("List destination attributes", path) }
        var existing = [CChar](repeating: 0, count: Int(existingCount))
        if existingCount > 0 {
            guard flistxattr(fd, &existing, existing.count, 0) == existingCount else { throw posix("Read destination attributes", path) }
            for name in existing.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) where attrs[name] == nil {
                guard fremovexattr(fd, name, 0) == 0 else { throw posix("Remove inherited attribute", path) }
            }
        }
        for (name, bytes) in attrs {
            guard bytes.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw posix("Preserve extended attribute", path) }
        }
        guard fchmod(fd, info.st_mode & 0o7777) == 0 else { throw posix("Preserve file permissions", path) }
        var times = [timespec(tv_sec: info.st_atimespec.tv_sec, tv_nsec: info.st_atimespec.tv_nsec), timespec(tv_sec: info.st_mtimespec.tv_sec, tv_nsec: info.st_mtimespec.tv_nsec)]
        guard futimens(fd, &times) == 0 else { throw posix("Preserve file timestamps", path) }
        // Creation time is best-effort only when the platform filesystem accepts setting it; capture refuses failure.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var creation = info.st_birthtimespec
        guard fsetattrlist(fd, &attributes, &creation, MemoryLayout<timespec>.size, 0) == 0 else { throw posix("Preserve creation timestamp", path) }
        guard fchflags(fd, info.st_flags) == 0 else { throw posix("Preserve ordinary document-tracking flag", path) }
    }
    static func entry(_ fd: Int32, path: String, device: UInt64) throws -> FileEntry {
        let before = try read(fd, path: path, device: device)
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw posix("Seek file", path) }
        var hash = SHA256(); var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posix("Hash file", path) }
            hash.update(data: Data(buffer.prefix(count)))
        }
        let after = try read(fd, path: path, device: device)
        guard before.stable(as: after) else { throw fail("File is changing; save and close its editor before retrying", path) }
        var metadata = SHA256()
        for key in before.attrs.keys.sorted() {
            let name = Data(key.utf8); var length = UInt64(name.count).bigEndian
            withUnsafeBytes(of: &length) { metadata.update(data: Data($0)) }
            metadata.update(data: name)
            let value = before.attrs[key]!; var valueLength = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &valueLength) { metadata.update(data: Data($0)) }
            metadata.update(data: value)
        }
        return FileEntry(path: path, size: UInt64(before.info.st_size), fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), metadataFingerprint: metadata.finalize().map { String(format: "%02x", $0) }.joined(), device: UInt64(before.info.st_dev), inode: UInt64(before.info.st_ino), mode: UInt32(before.info.st_mode & 0o7777), modifiedAt: Date(timeIntervalSince1970: Double(before.info.st_mtimespec.tv_sec) + Double(before.info.st_mtimespec.tv_nsec) / 1_000_000_000))
    }
}
