import Foundation
import XCTest
@testable import TryFolderCore

/// Concrete adversarial cases use retained synthetic fixtures, never real account documents.
final class SecurityRegressionTests: XCTestCase {
    func testJournalBeforeReservationCannotStrandRecoveryAfterAnotherStoresApply() async throws {
        let f = try AcceptanceFixture("security-journal-reservation-gap")
        let first = try f.engine()
        let second = try SessionEngine(storeURL: f.root.appendingPathComponent("Other store"))
        let a = try await first.create(source: f.source)
        let b = try await second.create(source: f.source)
        try write("owner reviewed\n", to: a.draftURL, path: "proposal.txt")
        try write("competing reviewed\n", to: b.draftURL, path: "proposal.txt")
        let ar = try await first.review(sessionID: a.id)
        let br = try await second.review(sessionID: b.id)
        let interrupted = try f.engine { if $0 == "apply.afterJournalPersisted" { throw AcceptanceFault.injected($0) } }
        await requireFailure("Interrupt after durable journal but before reservation") {
            try await interrupted.apply(sessionID: a.id, reviewID: ar.id, selectedPaths: ["proposal.txt"])
        }
        var competingApplied = false
        do {
            _ = try await second.apply(sessionID: b.id, reviewID: br.id, selectedPaths: ["proposal.txt"])
            competingApplied = true
        } catch { /* Conservatively reserving an overlapping source is acceptable. */ }
        // An untouched transaction may safely abort; it cannot strand recovery or undo later work.
        let recovered = try await first.recover(sessionID: a.id)
        XCTAssertEqual(recovered.state, .editing)
        XCTAssertEqual(try read(f.source, "proposal.txt"), competingApplied ? "competing reviewed\n" : "starting proposal\n")
        XCTAssertEqual(try read(a.baselineURL, "proposal.txt"), "starting proposal\n")
    }

    func testProtectedRootPolicyRejectsCaseAliasesAndCredentialRoots() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/library/Application Support", home + "/.ssh", home + "/.aws", home + "/.gnupg", "/applications/Utilities"] {
            XCTAssertThrowsError(try SafePath.validateSource(URL(fileURLWithPath: path)), path)
        }
    }

    func testCaseAliasedGitDirectoryIsExcludedWithoutTraversal() async throws {
        let f = try AcceptanceFixture("security-case-exclusion")
        try write("private repository metadata", to: f.source, path: ".GIT/config")
        let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        XCTAssertTrue(session.excluded.contains { $0.path == ".GIT" })
        XCTAssertFalse(exists(session.draftURL, ".GIT/config"))
        XCTAssertEqual(try read(f.source, ".GIT/config"), "private repository metadata")
    }

    func testFirmlinkAliasedStoreInsideSourceIsRejectedBeforeSessionCreation() async throws {
        let f = try AcceptanceFixture("security-firmlink-alias")
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + f.store.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("This host has no applicable Data-volume firmlink alias.") }
        let canonicalStore = try SafeDirectory(f.store)
        let aliasedStore = try SafeDirectory(alias)
        guard canonicalStore.identity == aliasedStore.identity else { throw XCTSkip("The host exposes distinct directories for the Data-volume alias.") }
        let before = try canonicalStore.names()
        let engine = try SessionEngine(storeURL: alias)
        await requireFailure("Store identity inside source must be rejected despite its alternate absolute path") {
            try await engine.create(source: f.root)
        }
        XCTAssertEqual(try canonicalStore.names(), before, "A disjointness rejection must precede all source/session writes")
    }

    func testTamperedDisplacedRecoveryBytesNeverReplaceCurrentSource() async throws {
        let f = try AcceptanceFixture("security-tampered-displaced")
        let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("reviewed bytes\n", to: session.draftURL, path: "proposal.txt")
        let review = try await engine.review(sessionID: session.id)
        let interrupted = try f.engine { if $0 == "apply.afterMutation" { throw AcceptanceFault.injected($0) } }
        await requireFailure("Apply must interrupt after its swap") {
            try await interrupted.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"])
        }
        let root = try SafeDirectory(session.sessionURL)
        let journal = try DurableJSON.read(MutationJournal.self, from: root, path: "journal.json")
        let transaction = session.sessionURL.appendingPathComponent("transactions/\(journal.id.uuidString)")
        try write("corrupted retained image\n", to: transaction, path: "staged/proposal.txt")
        await requireFailure("Ambiguous recovery material must be rejected before changing source") {
            try await engine.recover(sessionID: session.id)
        }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "reviewed bytes\n")
        XCTAssertEqual(try read(session.baselineURL, "proposal.txt"), "starting proposal\n")
        XCTAssertEqual(try read(review.snapshotURL, "proposal.txt"), "reviewed bytes\n")
    }

    func testTamperedReviewCannotRelabelAConflictAndOverwriteLaterSourceEdit() async throws {
        let f = try AcceptanceFixture("security-tampered-review-conflict")
        let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("sealed draft\n", to: session.draftURL, path: "proposal.txt")
        try write("newer independent source edit\n", to: f.source, path: "proposal.txt")
        var review = try await engine.review(sessionID: session.id)
        let index = try XCTUnwrap(review.changes.firstIndex { $0.path == "proposal.txt" })
        XCTAssertEqual(review.changes[index].kind, .conflict)
        // Corrupt only the saved changeset; the baseline and sealed manifest remain authentic.
        review.changes[index].baseline = review.changes[index].current
        review.changes[index].kind = .edited
        let root = try SafeDirectory(session.sessionURL)
        try DurableJSON.write(review, to: root, path: "review.json")
        await requireFailure("A JSON changeset cannot override the validated baseline's conflict result") {
            try await engine.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"])
        }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "newer independent source edit\n")
        XCTAssertEqual(try read(session.baselineURL, "proposal.txt"), "starting proposal\n")
    }

    func testTamperedJournalCannotClaimCompletionAheadOfItsTransaction() async throws {
        let f = try AcceptanceFixture("security-tampered-journal-status")
        let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("reviewed bytes\n", to: session.draftURL, path: "proposal.txt")
        let review = try await engine.review(sessionID: session.id)
        let interrupted = try f.engine { if $0 == "apply.afterMutation" { throw AcceptanceFault.injected($0) } }
        await requireFailure("Apply must leave an active transaction") {
            try await interrupted.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["proposal.txt"])
        }
        let root = try SafeDirectory(session.sessionURL)
        var journal = try DurableJSON.read(MutationJournal.self, from: root, path: "journal.json")
        journal.status = "committed"
        try DurableJSON.write(journal, to: root, path: "journal.json")
        await requireFailure("A completion pointer ahead of its durable transaction is malformed") {
            try await engine.recover(sessionID: session.id)
        }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "reviewed bytes\n")
        XCTAssertEqual(try read(session.baselineURL, "proposal.txt"), "starting proposal\n")
    }

    func testReplacedInnerAncestorIsRejectedBeforeAnyMutation() async throws {
        let f = try AcceptanceFixture("security-inner-ancestor")
        try write("tracked original\n", to: f.source, path: "Folder/file.txt")
        let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("reviewed folder bytes\n", to: session.draftURL, path: "Folder/file.txt")
        let review = try await engine.review(sessionID: session.id)
        let raced = try f.engine { hook in
            guard hook == "apply.beforeMutation" else { return }
            try FileManager.default.moveItem(at: f.source.appendingPathComponent("Folder"), to: f.outside.appendingPathComponent("Moved folder"))
            try write("unrelated replacement\n", to: f.source, path: "Folder/file.txt")
        }
        await requireFailure("An inner ancestor replaced after validation must stop mutation") {
            try await raced.apply(sessionID: session.id, reviewID: review.id, selectedPaths: ["Folder/file.txt"])
        }
        XCTAssertEqual(try read(f.source, "Folder/file.txt"), "unrelated replacement\n")
        XCTAssertEqual(try read(f.outside, "Moved folder/file.txt"), "tracked original\n")
    }
}
