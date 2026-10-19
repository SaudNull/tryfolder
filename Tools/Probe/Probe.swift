import Foundation
import Darwin
import TryFolderCore

// Developer-only executable for real subprocess interruption and disclosed measurements.
// Never bundled with the app. All writable paths must be inside a new caller-chosen fixture root.
@main struct Probe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw NSError(domain: "ProbeUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "TryFolderProbe benchmark|crash-apply|crash-undo|recover <new-fixture-root> [fault-hook]"]) }
        let command = args[0], root = URL(fileURLWithPath: args[1], isDirectory: true)
        let fm = FileManager.default
        let source = root.appendingPathComponent("Source"), store = root.appendingPathComponent("Store")
        if command == "recover" {
            let engine = try SessionEngine(storeURL: store)
            let sessions = try await engine.listSessions()
            guard let session = sessions.first else { throw NSError(domain: "Probe", code: 2) }
            let before = session.state.rawValue
            let recovered = try await engine.recover(sessionID: session.id)
            _ = try await engine.recover(sessionID: session.id)
            print("Recovered \(before) → \(recovered.state.rawValue)")
            return
        }
        guard !fm.fileExists(atPath: root.path) else { throw NSError(domain: "Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Fixture root must not already exist."]) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("starting\n".utf8).write(to: source.appendingPathComponent("edit.txt"))
        try Data("removed\n".utf8).write(to: source.appendingPathComponent("remove.txt"))
        if command == "benchmark" {
            for index in 0..<1000 { try Data(repeating: UInt8(index % 251), count: 4096).write(to: source.appendingPathComponent("document-\(index).txt")) }
            let large = source.appendingPathComponent("large.dat")
            fm.createFile(atPath: large.path, contents: nil)
            let output = try FileHandle(forWritingTo: large)
            let block = Data(repeating: 42, count: 1024 * 1024)
            for _ in 0..<128 { try output.write(contentsOf: block) }
            try output.close()
        }
        let engine = try SessionEngine(storeURL: store)
        let start = Date()
        let session = try await engine.create(source: source)
        let preparation = Date().timeIntervalSince(start)
        try Data("reviewed\n".utf8).write(to: session.draftURL.appendingPathComponent("edit.txt"))
        try Data("added\n".utf8).write(to: session.draftURL.appendingPathComponent("added.txt"))
        try fm.removeItem(at: session.draftURL.appendingPathComponent("remove.txt"))
        let reviewStart = Date()
        let review = try await engine.review(sessionID: session.id)
        let reviewTime = Date().timeIntervalSince(reviewStart)
        let selected: Set<String> = ["edit.txt", "added.txt", "remove.txt"]
        if command == "benchmark" {
            let results: [String: Any] = ["fixtureFiles": 1003, "fixtureBytes": 138313745, "prepareSeconds": preparation, "reviewSeconds": reviewTime, "changeCount": review.changes.count, "store": store.path, "sessionID": session.id.uuidString]
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else if command == "crash-apply" || command == "crash-undo" {
            guard args.count == 3 else { throw NSError(domain: "Probe", code: 4) }
            let specification = args[2].split(separator: "@", maxSplits: 1).map(String.init)
            let point = specification[0]
            let occurrence = specification.count > 1 ? Int(specification[1]) ?? 1 : 1
            let counter = ProbeCounter()
            if command == "crash-undo" { _ = try await engine.apply(sessionID: session.id, reviewID: review.id, selectedPaths: selected) }
            let crash = try SessionEngine(storeURL: store, fault: { hook in if hook == point && counter.next() == occurrence { _exit(86) } })
            if command == "crash-apply" { _ = try await crash.apply(sessionID: session.id, reviewID: review.id, selectedPaths: selected) }
            else { _ = try await crash.undo(sessionID: session.id) }
            throw NSError(domain: "Probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Requested fault hook was not reached."])
        } else { throw NSError(domain: "Probe", code: 6) }
    }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
