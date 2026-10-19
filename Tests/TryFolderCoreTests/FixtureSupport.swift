import Foundation
import XCTest
import Darwin
@testable import TryFolderCore

/// Synthetic, retained roots use an explicit test location or the checkout's Artifacts directory.
struct AcceptanceFixture {
    let root: URL
    let source: URL
    let store: URL
    let outside: URL

    init(_ name: String = #function) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let testRuns: URL
        if let configured = ProcessInfo.processInfo.environment["TRYFOLDER_TEST_ROOT"] {
            guard configured.hasPrefix("/"), !configured.isEmpty else {
                throw NSError(domain: "TryFolderAcceptanceFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "TRYFOLDER_TEST_ROOT must be an absolute directory path."])
            }
            testRuns = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            testRuns = repository.appendingPathComponent("Artifacts/TestRuns", isDirectory: true)
        }
        root = testRuns.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "_"))-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        store = root.appendingPathComponent("Sessions", isDirectory: true)
        outside = root.appendingPathComponent("Unrelated", isDirectory: true)
        for url in [source, store, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try write("starting proposal\n", to: source, path: "proposal.txt")
        try write("keep this source\n", to: source, path: "untouched.txt")
        try write("unrelated sentinel\n", to: outside, path: "sentinel.txt")
    }

    func engine(fault: (@Sendable (String) throws -> Void)? = nil) throws -> SessionEngine {
        try SessionEngine(storeURL: store, fault: fault)
    }

    func output(_ name: String = "Kept output") -> URL { root.appendingPathComponent(name, isDirectory: true) }
}

func write(_ value: String, to root: URL, path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}

func read(_ root: URL, _ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func exists(_ root: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

func requireFailure<T>(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail(message, file: file, line: line) }
    catch { /* A rejected operation is expected; callers independently verify preserved bytes. */ }
}

enum AcceptanceFault: Error { case injected(String) }

final class AcceptanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var expired = false
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func pause() {
        lock.lock(); entered = true; lock.unlock()
        if release.wait(timeout: .now() + 5) == .timedOut { lock.lock(); expired = true; lock.unlock() }
    }
    func resume() { release.signal() }
}

func setAttribute(_ name: String, bytes: Data, url: URL) throws {
    let result = url.path.withCString { path in name.withCString { attribute in
        bytes.withUnsafeBytes { value in Darwin.setxattr(path, attribute, value.baseAddress, value.count, 0, 0) }
    } }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

func attribute(_ name: String, url: URL) throws -> Data {
    let size = url.path.withCString { path in name.withCString { Darwin.getxattr(path, $0, nil, 0, 0, 0) } }
    guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var bytes = Data(count: size)
    let count = bytes.withUnsafeMutableBytes { buffer in url.path.withCString { path in name.withCString {
        Darwin.getxattr(path, $0, buffer.baseAddress, buffer.count, 0, 0)
    } } }
    guard count == size else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return bytes
}
