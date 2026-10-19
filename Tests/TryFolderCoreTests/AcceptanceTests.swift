import Foundation
import XCTest
import Darwin
@testable import TryFolderCore

final class AcceptanceTests: XCTestCase {
    func testDraftIsolationAndDiscardPreserveOriginalAndUnrelatedPaths() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        let session = try await engine.create(source: f.source)
        try write("draft edit\n", to: session.draftURL, path: "proposal.txt")
        try write("new draft\n", to: session.draftURL, path: "new.txt")
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
        XCTAssertEqual(try read(session.baselineURL, "proposal.txt"), "starting proposal\n")
        XCTAssertFalse(exists(f.source, "new.txt"))
        let discarded = try await engine.discard(sessionID: session.id)
        XCTAssertEqual(discarded.state, .discarded)
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
        XCTAssertEqual(try read(f.outside, "sentinel.txt"), "unrelated sentinel\n")
    }

    func testApplyAddEditRemoveAndPreserveUnselectedFile() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        try write("delete me\n", to: f.source, path: "remove.txt")
        let s = try await engine.create(source: f.source)
        try write("approved edit\n", to: s.draftURL, path: "proposal.txt")
        try write("unselected edit\n", to: s.draftURL, path: "untouched.txt")
        try write("approved addition\n", to: s.draftURL, path: "added.txt")
        try FileManager.default.removeItem(at: s.draftURL.appendingPathComponent("remove.txt"))
        let review = try await engine.review(sessionID: s.id)
        XCTAssertEqual(review.changes.first { $0.path == "proposal.txt" }?.kind, .edited)
        XCTAssertEqual(review.changes.first { $0.path == "added.txt" }?.kind, .added)
        XCTAssertEqual(review.changes.first { $0.path == "remove.txt" }?.kind, .removed)
        let applied = try await engine.apply(sessionID: s.id, reviewID: review.id, selectedPaths: ["proposal.txt", "added.txt", "remove.txt"])
        XCTAssertEqual(applied.state, .applied)
        XCTAssertEqual(try read(f.source, "proposal.txt"), "approved edit\n")
        XCTAssertEqual(try read(f.source, "added.txt"), "approved addition\n")
        XCTAssertFalse(exists(f.source, "remove.txt"))
        XCTAssertEqual(try read(f.source, "untouched.txt"), "keep this source\n")
    }

    func testChangedOriginalConflictsAndPreservesBothVersions() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("draft version\n", to: s.draftURL, path: "proposal.txt")
        try write("external version\n", to: f.source, path: "proposal.txt")
        let r = try await engine.review(sessionID: s.id)
        XCTAssertEqual(r.changes.first { $0.path == "proposal.txt" }?.kind, .conflict)
        await requireFailure("Conflicting source must not be overwritten") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "external version\n")
        XCTAssertEqual(try read(s.draftURL, "proposal.txt"), "draft version\n")
        let kept = try await engine.keep(sessionID: s.id, reviewID: r.id, destination: f.output())
        XCTAssertEqual(try read(kept, "proposal.txt"), "draft version\n")
    }

    func testOriginalChangedAfterReviewIsRevalidatedBeforeApply() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("reviewed\n", to: s.draftURL, path: "proposal.txt")
        let r = try await engine.review(sessionID: s.id)
        try write("later original\n", to: f.source, path: "proposal.txt")
        await requireFailure("Apply must revalidate source after review") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "later original\n")
    }

    func testApplyUsesSealedRevisionWhenLiveDraftChanges() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("approved bytes\n", to: s.draftURL, path: "proposal.txt")
        let r = try await engine.review(sessionID: s.id)
        try write("unreviewed bytes\n", to: s.draftURL, path: "proposal.txt")
        _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"])
        XCTAssertEqual(try read(f.source, "proposal.txt"), "approved bytes\n")
    }

    func testTamperedSealedSnapshotIsRejected() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("approved\n", to: s.draftURL, path: "proposal.txt")
        let r = try await engine.review(sessionID: s.id)
        try write("tampered\n", to: r.snapshotURL, path: "proposal.txt")
        await requireFailure("Tampered review must not apply") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
        await requireFailure("Tampered review must not export") { try await engine.keep(sessionID: s.id, reviewID: r.id, destination: f.output()) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testRejectsSymlinkAndHardLinkInputs() async throws {
        for kind in ["symbolic", "hard"] {
            let f = try AcceptanceFixture(kind); let engine = try f.engine()
            let target = f.outside.appendingPathComponent("sentinel.txt"); let link = f.source.appendingPathComponent("link.txt")
            if kind == "symbolic" { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
            else { try FileManager.default.linkItem(at: target, to: link) }
            await requireFailure("Unsupported \(kind) link must reject capture") { try await engine.create(source: f.source) }
            XCTAssertEqual(try read(f.outside, "sentinel.txt"), "unrelated sentinel\n")
        }
    }

    func testTraversalAndUnknownSelectedPathsCannotEscape() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("edit\n", to: s.draftURL, path: "proposal.txt"); let r = try await engine.review(sessionID: s.id)
        for path in ["../Unrelated/sentinel.txt", f.outside.appendingPathComponent("sentinel.txt").path, "proposal.txt/../../Unrelated/sentinel.txt", "absent.txt"] {
            await requireFailure("Invalid selection must reject: \(path)") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: [path]) }
        }
        XCTAssertEqual(try read(f.outside, "sentinel.txt"), "unrelated sentinel\n")
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testReplacedSourceAncestorDoesNotRedirectApply() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        let parent = f.root.appendingPathComponent("Parent"); let source = parent.appendingPathComponent("Selected")
        try write("original\n", to: source, path: "file.txt")
        let s = try await engine.create(source: source)
        try write("draft\n", to: s.draftURL, path: "file.txt"); let r = try await engine.review(sessionID: s.id)
        try write("outside\n", to: f.outside.appendingPathComponent("Selected"), path: "file.txt")
        try FileManager.default.moveItem(at: parent, to: f.root.appendingPathComponent("Saved parent"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: f.outside)
        await requireFailure("A replaced ancestor must not redirect mutation") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["file.txt"]) }
        XCTAssertEqual(try read(f.outside.appendingPathComponent("Selected"), "file.txt"), "outside\n")
        XCTAssertEqual(try read(f.root.appendingPathComponent("Saved parent/Selected"), "file.txt"), "original\n")
    }

    func testOverlappingAndExcludedSourceRootsAreRejected() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        await requireFailure("Store cannot contain source") { try await engine.create(source: f.store) }
        await requireFailure("Source cannot contain store") { try await engine.create(source: f.root) }
        for name in ["Fake.app", "Photos.photoslibrary", ".git"] {
            let url = f.root.appendingPathComponent(name); try write("synthetic", to: url, path: "file.txt")
            await requireFailure("Unsupported root must reject: \(name)") { try await engine.create(source: url) }
        }
    }

    func testArabicUnicodeQuotesNewlineAndLeadingHyphenRoundTrip() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        let names = ["دراسة project.txt", "quote ' and \".txt", "line\nbreak.txt", "-leading.txt", "emoji 📚.txt", "café.txt"]
        for name in names { try write("start: \(name)", to: f.source, path: name) }
        let s = try await engine.create(source: f.source)
        for name in names { try write("changed: \(name)", to: s.draftURL, path: name) }
        let r = try await engine.review(sessionID: s.id)
        XCTAssertEqual(Set(r.changes.filter(\.canApply).map(\.path)), Set(names))
        _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: Set(names))
        for name in names { XCTAssertEqual(try read(f.source, name), "changed: \(name)") }
    }

    func testCaseOnlyRenameCannotOverwriteOrLoseBytes() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        try write("case payload\n", to: f.source, path: "Report.txt")
        let s = try await engine.create(source: f.source)
        let temp = s.draftURL.appendingPathComponent("intermediate.txt")
        try FileManager.default.moveItem(at: s.draftURL.appendingPathComponent("Report.txt"), to: temp)
        try FileManager.default.moveItem(at: temp, to: s.draftURL.appendingPathComponent("report.txt"))
        do {
            let r = try await engine.review(sessionID: s.id)
            await requireFailure("Case-only rename is deferred by contract") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["Report.txt", "report.txt"]) }
        } catch { /* Rejecting review is an acceptable conservative result. */ }
        XCTAssertEqual(try read(f.source, "Report.txt"), "case payload\n")
    }

    func testApplyInterruptionAtEachBoundaryRecoversIdempotently() async throws {
        let hooks = ["apply.afterJournal", "apply.beforeMutation", "apply.afterMutation", "apply.beforeVerified", "apply.afterVerified", "apply.beforeCommit"]
        for hook in hooks {
            let f = try AcceptanceFixture(hook); let setup = try f.engine(); let s = try await setup.create(source: f.source)
            try write("reviewed\n", to: s.draftURL, path: "proposal.txt")
            let r = try await setup.review(sessionID: s.id)
            let faulty = try f.engine { if $0 == hook { throw AcceptanceFault.injected(hook) } }
            await requireFailure("Hook must interrupt \(hook)") { try await faulty.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
            let relaunched = try f.engine()
            let interrupted = try await relaunched.listSessions().first { $0.id == s.id }
            XCTAssertEqual(interrupted?.state, .recoveryNeeded, hook)
            let recovered = try await relaunched.recover(sessionID: s.id)
            XCTAssertEqual(recovered.state, .editing, hook)
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n", hook)
            XCTAssertEqual(try read(s.baselineURL, "proposal.txt"), "starting proposal\n", hook)
            XCTAssertEqual(try read(r.snapshotURL, "proposal.txt"), "reviewed\n", hook)
            _ = try await relaunched.recover(sessionID: s.id)
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n", hook)
        }
    }

    func testPreparationFailuresPreserveSource() async throws {
        for errorCode in [ENOSPC, EACCES, EIO] {
            let f = try AcceptanceFixture("errno-\(errorCode)")
            let engine = try f.engine { if $0 == "create.afterBaseline" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode)) } }
            await requireFailure("Injected creation failure must propagate") { try await engine.create(source: f.source) }
            XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
            XCTAssertEqual(try read(f.outside, "sentinel.txt"), "unrelated sentinel\n")
        }
    }

    func testUndoInterruptionAtEachBoundaryPreservesAppliedRevision() async throws {
        for hook in ["undo.afterJournal", "undo.beforeMutation", "undo.afterMutation", "undo.beforeVerified", "undo.afterVerified", "undo.beforeCommit"] {
            let f = try AcceptanceFixture(hook); let engine = try f.engine(); let s = try await engine.create(source: f.source)
            try write("applied bytes\n", to: s.draftURL, path: "proposal.txt"); let r = try await engine.review(sessionID: s.id)
            _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"])
            let faulty = try f.engine { if $0 == hook { throw AcceptanceFault.injected(hook) } }
            await requireFailure("Undo hook must interrupt: \(hook)") { try await faulty.undo(sessionID: s.id) }
            let relaunched = try f.engine(); _ = try await relaunched.recover(sessionID: s.id)
            XCTAssertEqual(try read(f.source, "proposal.txt"), "applied bytes\n", hook)
            XCTAssertEqual(try read(s.baselineURL, "proposal.txt"), "starting proposal\n", hook)
            XCTAssertEqual(try read(r.snapshotURL, "proposal.txt"), "applied bytes\n", hook)
        }
    }

    func testRecoveryInterruptionCanResumeAndPreservesLaterExternalEdits() async throws {
        for recoveryHook in ["recover.beforeMutation", "recover.afterMutation", "external-edit"] {
            let f = try AcceptanceFixture(recoveryHook); let engine = try f.engine(); let s = try await engine.create(source: f.source)
            try write("reviewed\n", to: s.draftURL, path: "proposal.txt"); let r = try await engine.review(sessionID: s.id)
            let interrupted = try f.engine { if $0 == "apply.afterMutation" { throw AcceptanceFault.injected($0) } }
            await requireFailure("Apply should interrupt") { try await interrupted.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
            if recoveryHook == "external-edit" {
                try write("external after interruption\n", to: f.source, path: "proposal.txt")
                let relaunched = try f.engine()
                await requireFailure("Recovery must preserve newer edits") { try await relaunched.recover(sessionID: s.id) }
                XCTAssertEqual(try read(f.source, "proposal.txt"), "external after interruption\n")
            } else {
                let failingRecovery = try f.engine { if $0 == recoveryHook { throw AcceptanceFault.injected($0) } }
                await requireFailure("Recovery hook must interrupt") { try await failingRecovery.recover(sessionID: s.id) }
                let relaunched = try f.engine(); _ = try await relaunched.recover(sessionID: s.id)
                XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
            }
            XCTAssertEqual(try read(r.snapshotURL, "proposal.txt"), "reviewed\n")
            XCTAssertEqual(try read(s.baselineURL, "proposal.txt"), "starting proposal\n")
        }
    }

    func testOverlappingMutationAcrossIndependentStoresIsGuarded() async throws {
        let f = try AcceptanceFixture(); let first = try f.engine()
        let second = try SessionEngine(storeURL: f.root.appendingPathComponent("Other sessions"))
        let a = try await first.create(source: f.source); let b = try await second.create(source: f.source)
        try write("first reviewed\n", to: a.draftURL, path: "proposal.txt")
        try write("second reviewed\n", to: b.draftURL, path: "proposal.txt")
        let ar = try await first.review(sessionID: a.id); let br = try await second.review(sessionID: b.id)
        let gate = AcceptanceGate()
        let paused = try f.engine { if $0 == "apply.beforeMutation" { gate.pause() } }
        let firstTask = Task.detached { try await paused.apply(sessionID: a.id, reviewID: ar.id, selectedPaths: ["proposal.txt"]) }
        for _ in 0..<200 where !gate.didEnter { try await Task.sleep(nanoseconds: 10_000_000) }
        guard gate.didEnter else { gate.resume(); _ = try? await firstTask.value; XCTFail("Mutation hook was not reached"); return }
        await requireFailure("Overlapping engine with independent store must be rejected while guard is held") { try await second.apply(sessionID: b.id, reviewID: br.id, selectedPaths: ["proposal.txt"]) }
        gate.resume(); _ = try await firstTask.value
        XCTAssertFalse(gate.didExpire, "A competing mutation blocked beyond the bounded guard check")
        XCTAssertEqual(try read(f.source, "proposal.txt"), "first reviewed\n")
    }

    func testMissingSourceStillAllowsKeepingReviewedDraft() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("draft survives\n", to: s.draftURL, path: "proposal.txt")
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("Moved source"))
        let r = try await engine.review(sessionID: s.id)
        XCTAssertFalse(r.sourceAvailable)
        let output = try await engine.keep(sessionID: s.id, reviewID: r.id, destination: f.output())
        XCTAssertEqual(try read(output, "proposal.txt"), "draft survives\n")
        await requireFailure("Missing original must not be recreated by Apply") { try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
    }

    func testUnavailableStoreFailsWithoutTouchingSource() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try FileManager.default.moveItem(at: f.store, to: f.root.appendingPathComponent("Detached sessions"))
        await requireFailure("Unavailable session storage must fail") { try await engine.review(sessionID: s.id) }
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testUndoRestoresAddEditRemoveAndProtectsLaterEdits() async throws {
        for laterEdit in [false, true] {
            let f = try AcceptanceFixture(); let engine = try f.engine()
            try write("removed original\n", to: f.source, path: "removed.txt")
            let s = try await engine.create(source: f.source)
            try write("applied\n", to: s.draftURL, path: "proposal.txt")
            try write("added\n", to: s.draftURL, path: "added.txt")
            try FileManager.default.removeItem(at: s.draftURL.appendingPathComponent("removed.txt"))
            let r = try await engine.review(sessionID: s.id)
            _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt", "added.txt", "removed.txt"])
            if laterEdit {
                try write("newer external edit\n", to: f.source, path: "proposal.txt")
                await requireFailure("Undo must preserve newer external edit") { try await engine.undo(sessionID: s.id) }
                XCTAssertEqual(try read(f.source, "proposal.txt"), "newer external edit\n")
            } else {
                let undone = try await engine.undo(sessionID: s.id)
                XCTAssertEqual(undone.state, .editing)
                XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
                XCTAssertEqual(try read(f.source, "removed.txt"), "removed original\n")
                XCTAssertFalse(exists(f.source, "added.txt"))
            }
        }
    }

    func testMetadataAndResourceForkPreservedThroughCaptureApplyUndo() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let original = f.source.appendingPathComponent("proposal.txt")
        let attributes = ["com.tryfolder.acceptance": Data("ordinary attribute".utf8), "com.apple.ResourceFork": Data("synthetic resource fork bytes".utf8)]
        for (name, bytes) in attributes { try setAttribute(name, bytes: bytes, url: original) }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original.path)
        let s = try await engine.create(source: f.source)
        for root in [s.baselineURL, s.draftURL] {
            for (name, bytes) in attributes { XCTAssertEqual(try attribute(name, url: root.appendingPathComponent("proposal.txt")), bytes) }
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("proposal.txt").path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        }
        try setAttribute("com.tryfolder.acceptance", bytes: Data("edited attribute".utf8), url: s.draftURL.appendingPathComponent("proposal.txt"))
        let r = try await engine.review(sessionID: s.id)
        XCTAssertEqual(r.changes.first { $0.path == "proposal.txt" }?.kind, .edited)
        _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["proposal.txt"])
        XCTAssertEqual(try attribute("com.tryfolder.acceptance", url: original), Data("edited attribute".utf8))
        XCTAssertEqual(try attribute("com.apple.ResourceFork", url: original), attributes["com.apple.ResourceFork"])
        _ = try await engine.undo(sessionID: s.id)
        for (name, bytes) in attributes { XCTAssertEqual(try attribute(name, url: original), bytes) }
    }

    func testRelaunchReconstructsUnfinishedDraftAndReview() async throws {
        let f = try AcceptanceFixture(); let first = try f.engine(); let s = try await first.create(source: f.source)
        try write("retained draft\n", to: s.draftURL, path: "proposal.txt")
        let r = try await first.review(sessionID: s.id)
        let relaunched = try f.engine()
        let restored = try await relaunched.listSessions().first { $0.id == s.id }
        XCTAssertEqual(restored?.state, .readyToApply)
        let restoredReview = try await relaunched.loadReview(sessionID: s.id)
        XCTAssertEqual(restoredReview?.id, r.id)
        XCTAssertEqual(try read(restored!.draftURL, "proposal.txt"), "retained draft\n")
    }

    func testExcludedAndUnselectedDescendantsSurviveParentRemoval() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine()
        try write("tracked\n", to: f.source, path: "Folder/tracked.txt")
        try write("unselected\n", to: f.source, path: "Folder/unselected.txt")
        try write("protected metadata\n", to: f.source, path: "Folder/.git/config")
        let s = try await engine.create(source: f.source)
        XCTAssertTrue(s.excluded.contains { $0.path == "Folder/.git" || $0.path.hasPrefix("Folder/.git/") })
        XCTAssertFalse(exists(s.draftURL, "Folder/.git/config"))
        try FileManager.default.removeItem(at: s.draftURL.appendingPathComponent("Folder"))
        let r = try await engine.review(sessionID: s.id)
        XCTAssertFalse(r.changes.contains { $0.path.hasPrefix("Folder/.git") && $0.canApply })
        _ = try await engine.apply(sessionID: s.id, reviewID: r.id, selectedPaths: ["Folder/tracked.txt"])
        XCTAssertFalse(exists(f.source, "Folder/tracked.txt"))
        XCTAssertEqual(try read(f.source, "Folder/unselected.txt"), "unselected\n")
        XCTAssertEqual(try read(f.source, "Folder/.git/config"), "protected metadata\n")
    }

    func testKeepThenDiscardPreservesUserOwnedOutputAndRejectsOverwrite() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source)
        try write("sealed export\n", to: s.draftURL, path: "proposal.txt"); let r = try await engine.review(sessionID: s.id)
        try write("later draft\n", to: s.draftURL, path: "proposal.txt")
        let output = try await engine.keep(sessionID: s.id, reviewID: r.id, destination: f.output())
        XCTAssertEqual(try read(output, "proposal.txt"), "sealed export\n")
        try write("user-owned edit\n", to: output, path: "proposal.txt")
        await requireFailure("Keep must reject existing destination") { try await engine.keep(sessionID: s.id, reviewID: r.id, destination: output) }
        _ = try await engine.discard(sessionID: s.id)
        let relaunched = try f.engine(); _ = try await relaunched.listSessions()
        XCTAssertEqual(try read(output, "proposal.txt"), "user-owned edit\n")
        XCTAssertEqual(try read(f.source, "proposal.txt"), "starting proposal\n")
    }

    func testExportRejectsSourceStoreAndManagedDescendants() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source); let r = try await engine.review(sessionID: s.id)
        for destination in [f.source.appendingPathComponent("out"), f.store.appendingPathComponent("out"), s.draftURL.appendingPathComponent("out")] {
            await requireFailure("Export destination must be disjoint") { try await engine.keep(sessionID: s.id, reviewID: r.id, destination: destination) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testCompetingExportsNeverMergeOrOverwrite() async throws {
        let f = try AcceptanceFixture(); let engine = try f.engine(); let s = try await engine.create(source: f.source); let r = try await engine.review(sessionID: s.id)
        let second = try f.engine(); let destination = f.output()
        async let first = exportResult(engine, sessionID: s.id, reviewID: r.id, destination: destination)
        async let competing = exportResult(second, sessionID: s.id, reviewID: r.id, destination: destination)
        let results = await [first, competing]
        let diagnostic = results.enumerated().map { "Export \($0.offset + 1): \($0.element.diagnostic)" }.joined(separator: "\n")
        try write(diagnostic + "\n", to: f.root, path: "export-results.txt")
        print("Competing export evidence: \(f.root.path)\n\(diagnostic)")
        let successes = results.filter(\.succeeded).count
        XCTAssertEqual(successes, 1, diagnostic)
        guard successes == 1 else { return }
        XCTAssertEqual(try read(destination, "proposal.txt"), "starting proposal\n")
        XCTAssertEqual(try read(destination, "untouched.txt"), "keep this source\n")
    }

    private struct ExportResult: Sendable {
        let succeeded: Bool
        let diagnostic: String
    }

    private func exportResult(_ engine: SessionEngine, sessionID: UUID, reviewID: UUID, destination: URL) async -> ExportResult {
        do {
            let output = try await engine.keep(sessionID: sessionID, reviewID: reviewID, destination: destination)
            return ExportResult(succeeded: true, diagnostic: "success: \(output.path)")
        } catch {
            let nsError = error as NSError
            return ExportResult(succeeded: false, diagnostic: "\(String(reflecting: error)); domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)")
        }
    }
}
