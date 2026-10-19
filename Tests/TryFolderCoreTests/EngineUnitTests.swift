import Foundation
import XCTest
import Darwin
@testable import TryFolderCore

final class EngineUnitTests: XCTestCase {
    func testDocumentTrackingFlagSurvivesCaptureReviewApplyAndUndo() async throws {
        for initialFlags in [UInt32(0), UInt32(UF_TRACKED)] {
            let f = try AcceptanceFixture("document-tracking-\(initialFlags)"); let engine = try f.engine()
            let original = f.source.appendingPathComponent("proposal.txt")
            guard chflags(original.path, initialFlags) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let session = try await engine.create(source: f.source)
            XCTAssertEqual(try coreFlags(session.baselineURL.appendingPathComponent("proposal.txt")), initialFlags)
            XCTAssertEqual(try coreFlags(session.draftURL.appendingPathComponent("proposal.txt")), initialFlags)
            try write("ordinary TextEdit save", to: session.draftURL, path: "proposal.txt")
            guard chflags(session.draftURL.appendingPathComponent("proposal.txt").path, UInt32(UF_TRACKED)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard chflags(session.draftURL.appendingPathComponent("untouched.txt").path, UInt32(UF_TRACKED)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let review = try await engine.review(sessionID: session.id)
            XCTAssertEqual(review.changes.first { $0.path == "proposal.txt" }?.kind, .edited)
            XCTAssertFalse(review.changes.contains { $0.path == "untouched.txt" }, "A document-tracking identity toggle alone is not a semantic file edit")
            XCTAssertEqual(try coreFlags(review.snapshotURL.appendingPathComponent("proposal.txt")), UInt32(UF_TRACKED))
            _ = try await engine.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"])
            XCTAssertEqual(try read(f.source, "proposal.txt"), "ordinary TextEdit save")
            // APFS RENAME_SWAP preserves pathname document identity rather than moving UF_TRACKED
            // together with the content inode. Never rewrite source flags to force a reviewed identity.
            XCTAssertEqual(try coreFlags(original), initialFlags)
            _ = try await engine.undo(sessionID: session.id)
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
            XCTAssertEqual(try coreFlags(original), initialFlags)
        }
    }

    func testUnsupportedFilesystemFlagsRemainRejected() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        let original = f.source.appendingPathComponent("proposal.txt")
        guard chflags(original.path, UInt32(UF_NODUMP)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        await requireFailure("Supporting document tracking must not admit other filesystem flags") { try await engine.create(source: f.source) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
        XCTAssertEqual(try coreFlags(original), UInt32(UF_NODUMP))
    }

    func testFiftyCompetingExportsKeepWinningDescriptorsValid() async throws {
        let f = try AcceptanceFixture(); let first = try f.engine(); let second = try f.engine()
        let session = try await first.create(source: f.source)
        let review = try await first.review(sessionID: session.id)
        for index in 0..<50 {
            let destination = f.output("Competing output \(index)")
            async let a = coreExportResult(first, sessionID: session.id, reviewID: review.id, destination: destination)
            async let b = coreExportResult(second, sessionID: session.id, reviewID: review.id, destination: destination)
            let results = await [a, b]
            let successes = results.filter { $0 == nil }.count
            XCTAssertEqual(successes, 1, "Iteration \(index): \(results.map { $0 ?? "success" })")
            guard successes == 1 else { continue }
            XCTAssertEqual(try read(destination, "proposal.txt"), "starting proposal\n", "Iteration \(index)")
            XCTAssertEqual(try read(destination, "untouched.txt"), "keep this source\n", "Iteration \(index)")
        }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testFinderMetadataWithHiddenFlagIsExcludedFromCaptureAndReview() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        try write("Finder source metadata", to: f.source, path: ".DS_Store")
        let finderFile = f.source.appendingPathComponent(".DS_Store")
        guard chflags(finderFile.path, UInt32(UF_HIDDEN)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let session = try await engine.create(source: f.source)
        XCTAssertTrue(session.excluded.contains { $0.path == ".DS_Store" && $0.reason.contains("Finder") })
        XCTAssertFalse(exists(session.draftURL, ".DS_Store"))
        try write("Finder draft metadata", to: session.draftURL, path: ".DS_Store")
        let draftFinderFile = session.draftURL.appendingPathComponent(".DS_Store")
        guard chflags(draftFinderFile.path, UInt32(UF_HIDDEN)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try write("ordinary editor bytes", to: session.draftURL, path: "proposal.txt")
        let review = try await engine.review(sessionID: session.id)
        XCTAssertTrue(review.excluded.contains { $0.path == ".DS_Store" })
        XCTAssertFalse(review.changes.contains { $0.path == ".DS_Store" })
        XCTAssertEqual(review.changes.first { $0.path == "proposal.txt" }?.kind, .edited)
        XCTAssertEqual(try read(f.source, ".DS_Store"), "Finder source metadata")
    }

    func testPendingOwnerBlocksOverlappingSessionsAcrossSameAndDifferentStoresUntilRecovered() async throws {
        for separateStore in [false, true] {
            let f = try AcceptanceFixture("pending-owner-\(separateStore)")
            let first = try f.engine()
            let second = try SessionEngine(storeURL: separateStore ? f.root.appendingPathComponent("Second store") : f.store)
            let a = try await first.create(source: f.source), b = try await second.create(source: f.source)
            try write("owner partial", to: a.draftURL, path: "proposal.txt")
            try write("second reviewed", to: b.draftURL, path: "proposal.txt")
            let ar = try await first.review(sessionID: a.id), br = try await second.review(sessionID: b.id)
            let faulty = try f.engine { if $0 == "apply.afterMutation" { throw AcceptanceFault.injected($0) } }
            await requireFailure("Owner must interrupt") { try await faulty.apply(sessionID: a.id, reviewID: ar.id, selectedPaths: ["proposal.txt"]) }
            do {
                _ = try await second.apply(sessionID: b.id, reviewID: br.id, selectedPaths: ["proposal.txt"])
                XCTFail("Unresolved owner reservation must block another session")
            } catch { XCTAssertTrue(error.localizedDescription.contains("reserves an overlapping source"), error.localizedDescription) }
            XCTAssertEqual(try read(f.source, "proposal.txt"), "owner partial")
            let relaunchedOwner = try f.engine()
            _ = try await relaunchedOwner.recover(sessionID: a.id)
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
            let refreshed = try await second.review(sessionID: b.id)
            _ = try await second.apply(sessionID: b.id, reviewID: refreshed.id, selectedPaths: ["proposal.txt"])
            XCTAssertEqual(try read(f.source, "proposal.txt"), "second reviewed")
        }
    }

    func testReservationDurabilityGapsRecoverWithoutReleasingUncommittedOwner() async throws {
        for hook in ["apply.afterJournalPersisted", "apply.afterReservation", "apply.afterCommit", "apply.afterRelease"] {
            let f = try AcceptanceFixture(hook); let engine = try f.engine(); let s = try await engine.create(source: f.source)
            try write("reviewed", to: s.draftURL, path: "proposal.txt")
            let review = try await engine.review(sessionID: s.id)
            let faulty = try f.engine { if $0 == hook { throw AcceptanceFault.injected($0) } }
            await requireFailure("Durability hook must fire") { try await faulty.apply(sessionID: s.id, reviewID: review.id, selectedPaths: ["proposal.txt"]) }
            let restored = try await engine.recover(sessionID: s.id)
            let committed = hook == "apply.afterCommit" || hook == "apply.afterRelease"
            XCTAssertEqual(restored.state, committed ? .applied : .editing, hook)
            XCTAssertEqual(try read(f.source, "proposal.txt"), committed ? "reviewed" : "starting proposal\n", hook)
            let lock = try MutationLock()
            try lock.checkAvailable(source: SafeDirectory(f.source))
        }
    }

    func testUnavailableUnresolvedStoreDoesNotPruneItsReservation() async throws {
        let f = try AcceptanceFixture(); let first = try f.engine()
        let second = try SessionEngine(storeURL: f.root.appendingPathComponent("Second store"))
        let a = try await first.create(source: f.source), b = try await second.create(source: f.source)
        try write("owner partial", to: a.draftURL, path: "proposal.txt")
        try write("other", to: b.draftURL, path: "proposal.txt")
        let ar = try await first.review(sessionID: a.id), br = try await second.review(sessionID: b.id)
        let faulty = try f.engine { if $0 == "apply.afterMutation" { throw AcceptanceFault.injected($0) } }
        await requireFailure("Owner must interrupt") { try await faulty.apply(sessionID: a.id, reviewID: ar.id, selectedPaths: ["proposal.txt"]) }
        let moved = f.root.appendingPathComponent("Unavailable owner storage")
        try FileManager.default.moveItem(at: f.store, to: moved)
        do { _ = try await second.apply(sessionID: b.id, reviewID: br.id, selectedPaths: ["proposal.txt"]); XCTFail("Unavailable owner cannot be pruned") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reserves an overlapping source"), error.localizedDescription) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "owner partial")
        try FileManager.default.moveItem(at: moved, to: f.store)
        _ = try await first.recover(sessionID: a.id)
    }

    func testNestedAdditionsApplyAndUndoRetainOrdinaryEmptyDirectories() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("one", to: session.draftURL, path: "New/Deep/one.txt")
        try write("two", to: session.draftURL, path: "New/Deep/two.txt")
        let review = try await engine.review(sessionID: session.id)
        _ = try await engine.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["New/Deep/one.txt", "New/Deep/two.txt"])
        XCTAssertEqual(try read(f.source, "New/Deep/one.txt"), "one")
        _ = try await engine.undo(sessionID: session.id)
        XCTAssertFalse(exists(f.source, "New/Deep/one.txt"))
        XCTAssertFalse(exists(f.source, "New/Deep/two.txt"))
        XCTAssertTrue(exists(f.source, "New/Deep"), "Conservative Undo never recursively removes user directories")
        let refreshed = try await engine.review(sessionID: session.id)
        XCTAssertTrue(refreshed.changes.first { $0.path == "New/Deep/one.txt" }?.canApply == true)
        _ = try await engine.apply(sessionID: session.id, reviewID: refreshed.id, selectedPaths: ["New/Deep/one.txt", "New/Deep/two.txt"])
        XCTAssertEqual(try read(f.source, "New/Deep/two.txt"), "two")
    }

    func testUndoCanBeReviewedAndAppliedAgainWithoutChangingBaselineBytes() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let session = try await engine.create(source: f.source)
        try write("first reviewed", to: session.draftURL, path: "proposal.txt")
        let first = try await engine.review(sessionID: session.id)
        _ = try await engine.apply(sessionID: session.id, reviewID: first.id, selectedPaths: ["proposal.txt"])
        _ = try await engine.undo(sessionID: session.id)
        let second = try await engine.review(sessionID: session.id)
        XCTAssertEqual(second.changes.first { $0.path == "proposal.txt" }?.kind, .edited)
        _ = try await engine.apply(sessionID: session.id, reviewID: second.id, selectedPaths: ["proposal.txt"])
        XCTAssertEqual(try read(f.source, "proposal.txt"), "first reviewed")
        XCTAssertEqual(try read(session.baselineURL, "proposal.txt"), "starting proposal\n")
    }

    func testPartialMixedTransactionRecoversEveryPriorMutation() async throws {
        for faultPosition in [1, 2, 3] {
            let f = try AcceptanceFixture("mixed-\(faultPosition)"); let engine = try f.engine()
            try write("remove", to: f.source, path: "z-remove.txt")
            let session = try await engine.create(source: f.source)
            try write("add", to: session.draftURL, path: "a-added.txt")
            try write("edit", to: session.draftURL, path: "proposal.txt")
            try FileManager.default.removeItem(at: session.draftURL.appendingPathComponent("z-remove.txt"))
            let review = try await engine.review(sessionID: session.id)
            let counter = EngineFaultCounter()
            let faulty = try f.engine { if $0 == "apply.afterMutation", counter.next() == faultPosition { throw AcceptanceFault.injected($0) } }
            await requireFailure("Interrupt mixed transaction after selected mutation") {
                try await faulty.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["a-added.txt", "proposal.txt", "z-remove.txt"])
            }
            _ = try await engine.recover(sessionID: session.id)
            XCTAssertFalse(exists(f.source, "a-added.txt"))
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
            XCTAssertEqual(try read(f.source, "z-remove.txt"), "remove")
            _ = try await engine.recover(sessionID: session.id)
        }
    }

    func testCaptureDetectsSourceMutationBeforePublishingDraft() async throws {
        let f = try AcceptanceFixture()
        let engine = try f.engine { point in
            if point == "create.afterBaseline" { try write("external during capture", to: f.source, path: "proposal.txt") }
        }
        await requireFailure("Changing source is a busy capture, never a coherent baseline claim") { try await engine.create(source: f.source) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "external during capture")
        let listed = try await engine.listSessions()
        XCTAssertEqual(listed.first?.state, .interrupted)
    }

    func testTraversalInJournalIsRejectedWithoutSourceMutation() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let session = try await engine.create(source: f.source)
        try write("reviewed", to: session.draftURL, path: "proposal.txt")
        let review = try await engine.review(sessionID: session.id)
        let fault = try f.engine { if $0 == "apply.afterJournal" { throw AcceptanceFault.injected($0) } }
        await requireFailure("Leave a staged journal") { try await fault.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"]) }
        let root = try SafeDirectory(session.sessionURL)
        var journal = try DurableJSON.read(MutationJournal.self, from: root, path: "journal.json")
        journal.operations[0].path = "../Unrelated/sentinel.txt"
        try DurableJSON.write(journal, to: root, path: "journal.json")
        await requireFailure("Untrusted journal paths must never escape managed roots") { try await engine.recover(sessionID: session.id) }
        XCTAssertEqual(try read(f.outside, "sentinel.txt"), "unrelated sentinel\n")
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testStageTamperAtMutationBoundaryIsRejectedBeforeSourceChanges() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let session = try await engine.create(source: f.source)
        try write("reviewed", to: session.draftURL, path: "proposal.txt")
        let review = try await engine.review(sessionID: session.id)
        let faulty = try f.engine { point in
            if point == "apply.beforeMutation" {
                let root = try SafeDirectory(session.sessionURL)
                let journal = try DurableJSON.read(MutationJournal.self, from: root, path: "journal.json")
                try write("corrupt", to: session.sessionURL, path: "transactions/\(journal.id.uuidString)/staged/proposal.txt")
            }
        }
        await requireFailure("Staging corruption must be caught before swap") { try await faulty.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"]) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
        _ = try await engine.recover(sessionID: session.id)
    }
}

private final class EngineFaultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private func coreExportResult(_ engine: SessionEngine, sessionID: UUID, reviewID: UUID, destination: URL) async -> String? {
    do { _ = try await engine.keep(sessionID: sessionID, reviewID: reviewID, destination: destination); return nil }
    catch { return String(reflecting: error) + ": " + error.localizedDescription }
}

private func coreFlags(_ url: URL) throws -> UInt32 {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return value.st_flags
}
