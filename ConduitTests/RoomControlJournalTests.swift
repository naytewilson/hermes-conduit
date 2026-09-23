//
//  RoomControlJournalTests.swift
//  Conduit
//
//  Tests for the I4 corrective hardening of the control journal:
//  - P1-1: absent / healthy / unreadable / incompatible load states are
//    distinct; unreadable/incompatible POISON mutable controls, preserve the
//    raw evidence bytes, and require an explicit operator reset.
//  - P1-2: dashboard deletion retires only RESOLVED entries; pending/recorded
//    intents survive; a separate explicit API abandons unresolved intents.
//  - P1-3: crash-durable Application Support storage (temp write + fsync +
//    atomic rename); a failed commit throws and leaves in-memory state
//    untouched — the caller fails closed.
//
//  The journal is file-backed, so each test owns a per-test temp directory.

import Foundation
import XCTest
@testable import Conduit

final class RoomControlJournalTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomControlJournalTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeIntent(
        dashboardID: UUID = UUID(),
        action: RoomControlAction = .cancel
    ) -> RoomControlIntent {
        RoomControlIntent(
            id: UUID(),
            dashboardID: dashboardID,
            roomID: "room-1",
            executionID: "exec-1",
            action: action,
            attentionKind: nil,
            trigger: nil,
            projectSlug: nil,
            correlationID: nil,
            idempotencyKey: "conduit:test:\(UUID().uuidString)"
        )
    }

    private func journalFile() -> URL {
        dir.appendingPathComponent(RoomControlJournal.defaultFileName)
    }

    // MARK: - P1-1: load-state taxonomy and poisoning

    func testAbsentJournalLoadsEmpty() {
        let journal = RoomControlJournal(storageDirectory: dir)
        XCTAssertEqual(journal.loadState, .absent)
        XCTAssertFalse(journal.isPoisoned)
        XCTAssertNil(journal.poisonEvidence)
    }

    func testUnreadablePayloadPoisonsJournalAndPreservesEvidence() throws {
        let garbage = Data([UInt8]("not-json".utf8) + [0, 1] + [UInt8]("garbage".utf8))
        try garbage.write(to: journalFile(), options: .atomic)
        var journal = RoomControlJournal(storageDirectory: dir)
        XCTAssertEqual(journal.loadState, .unreadable)
        XCTAssertTrue(journal.isPoisoned)
        XCTAssertEqual(journal.poisonEvidence, garbage)
        // Mutable controls refuse.
        do {
            _ = try journal.recoverOrInsert(makeIntent(), at: Date())
            XCTFail("recoverOrInsert must throw on a poisoned journal")
        } catch let error as RoomControlJournal.JournalError {
            XCTAssertEqual(error, .poisoned)
        }
    }

    func testIncompatibleVersionPoisonsJournalAndPreservesEvidence() throws {
        let bad = Data(#"{"version":999,"entries":{},"order":[]}"#.utf8)
        try bad.write(to: journalFile(), options: .atomic)
        var journal = RoomControlJournal(storageDirectory: dir)
        XCTAssertEqual(journal.loadState, .incompatible(foundVersion: 999))
        XCTAssertTrue(journal.isPoisoned)
        XCTAssertEqual(journal.poisonEvidence, bad)
        do {
            _ = try journal.recoverOrInsert(makeIntent(), at: Date())
            XCTFail("recoverOrInsert must throw on a poisoned journal")
        } catch let error as RoomControlJournal.JournalError {
            XCTAssertEqual(error, .poisoned)
        }
    }

    func testUnreadableNonJSONBytesAreUnrecoverable() throws {
        // Data(contentsOf:) cannot even decode the bytes — the journal is
        // unreadable, and the partial bytes it holds are the evidence.
        let garbage = Data("plain ascii, not json".utf8)
        try garbage.write(to: journalFile(), options: .atomic)
        let journal = RoomControlJournal(storageDirectory: dir)
        XCTAssertEqual(journal.loadState, .unreadable)
        XCTAssertEqual(journal.poisonEvidence, garbage)
    }

    func testExplicitResetIsRequiredAndRestoresMutability() throws {
        let garbage = Data("not-json".utf8)
        try garbage.write(to: journalFile(), options: .atomic)
        var journal = RoomControlJournal(storageDirectory: dir)
        XCTAssertTrue(journal.isPoisoned)
        // Reset preserving the evidence returns the raw bytes.
        let evidence = try journal.resetPoisonedJournal(preservingEvidence: true)
        XCTAssertEqual(evidence, garbage)
        XCTAssertNil(journal.poisonEvidence)
        XCTAssertEqual(journal.loadState, .healthy)
        XCTAssertFalse(journal.isPoisoned)
        // Mutable controls work again after the explicit reset.
        let intent = makeIntent()
        let recovered = try journal.recoverOrInsert(intent, at: Date())
        XCTAssertEqual(recovered.id, intent.id)
    }

    func testResetDiscardsEvidenceWhenAsked() throws {
        let garbage = Data("not-json".utf8)
        try garbage.write(to: journalFile(), options: .atomic)
        var journal = RoomControlJournal(storageDirectory: dir)
        let evidence = try journal.resetPoisonedJournal(preservingEvidence: false)
        XCTAssertNil(evidence)
        XCTAssertNil(journal.poisonEvidence)
        XCTAssertEqual(journal.loadState, .healthy)
    }

    func testResetOnHealthyJournalThrowsNotPoisoned() throws {
        var journal = RoomControlJournal(storageDirectory: dir)
        do {
            _ = try journal.resetPoisonedJournal(preservingEvidence: true)
            XCTFail("reset on a healthy journal must throw")
        } catch let error as RoomControlJournal.JournalError {
            XCTAssertEqual(error, .notPoisoned)
        }
    }

    // MARK: - Upgrade migration from I4 UserDefaults journal

    func testLegacyUserDefaultsJournalMigratesBeforeEmptyFileJournal() throws {
        let suiteName = "RoomControlJournalTests.legacy.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated UserDefaults suite")
        }
        legacyDefaults.removePersistentDomain(forName: suiteName)
        defer { legacyDefaults.removePersistentDomain(forName: suiteName) }

        let seedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomControlJournalTests.seed.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: seedDir) }

        let dashboard = UUID()
        let original = makeIntent(dashboardID: dashboard, action: .retry)
        do {
            var seed = RoomControlJournal(
                storageDirectory: seedDir,
                legacyDefaults: legacyDefaults,
                legacyStorageKey: "unused.seed.\(UUID().uuidString)"
            )
            _ = try seed.recoverOrInsert(original, at: Date())
            try seed.recordOperation(
                intentID: original.id,
                operationID: "legacy-op-1",
                status: .recorded,
                at: Date()
            )
        }

        let legacyBytes = try Data(
            contentsOf: seedDir.appendingPathComponent(RoomControlJournal.defaultFileName)
        )
        legacyDefaults.set(legacyBytes, forKey: RoomControlJournal.legacyStorageKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile().path))

        var migrated = RoomControlJournal(
            storageDirectory: dir,
            legacyDefaults: legacyDefaults
        )

        XCTAssertEqual(migrated.loadState, .healthy)
        XCTAssertFalse(migrated.isPoisoned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalFile().path))
        XCTAssertNil(legacyDefaults.data(forKey: RoomControlJournal.legacyStorageKey))
        XCTAssertEqual(migrated.entry(intentID: original.id)?.operationID, "legacy-op-1")
        XCTAssertEqual(migrated.entry(intentID: original.id)?.phase, .recorded)

        let replacement = makeIntent(dashboardID: dashboard, action: .retry)
        let recovered = try migrated.recoverOrInsert(replacement, at: Date())
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.idempotencyKey, original.idempotencyKey)
    }

    func testLegacyMigrationFailureStaysPoisonedAndPreservesSourceBytes() throws {
        let suiteName = "RoomControlJournalTests.legacy-fail.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated UserDefaults suite")
        }
        legacyDefaults.removePersistentDomain(forName: suiteName)
        defer { legacyDefaults.removePersistentDomain(forName: suiteName) }

        let seedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomControlJournalTests.seed-fail.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: seedDir) }

        let original = makeIntent(action: .resume)
        do {
            var seed = RoomControlJournal(
                storageDirectory: seedDir,
                legacyDefaults: legacyDefaults,
                legacyStorageKey: "unused.seed.\(UUID().uuidString)"
            )
            _ = try seed.recoverOrInsert(original, at: Date())
        }
        let legacyBytes = try Data(
            contentsOf: seedDir.appendingPathComponent(RoomControlJournal.defaultFileName)
        )
        legacyDefaults.set(legacyBytes, forKey: RoomControlJournal.legacyStorageKey)

        // A file where the storage directory must be makes createDirectory fail.
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomControlJournalTests.blocked.\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }

        var journal = RoomControlJournal(
            storageDirectory: blockedDirectory,
            legacyDefaults: legacyDefaults
        )
        XCTAssertEqual(journal.loadState, .migrationFailed)
        XCTAssertTrue(journal.isPoisoned)
        XCTAssertEqual(journal.poisonEvidence, legacyBytes)
        XCTAssertEqual(
            legacyDefaults.data(forKey: RoomControlJournal.legacyStorageKey),
            legacyBytes,
            "failed migration must leave the legacy source intact for retry"
        )

        XCTAssertThrowsError(try journal.recoverOrInsert(makeIntent(), at: Date())) { error in
            XCTAssertEqual(error as? RoomControlJournal.JournalError, .poisoned)
        }
    }

    // MARK: - P1-2: dashboard deletion semantics

    func testClearDashboardPreservesPendingAndRecordedIntents() throws {
        var journal = RoomControlJournal(storageDirectory: dir)
        let dashboard = UUID()
        let other = UUID()
        let pending = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard), at: Date())
        let recorded = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard, action: .retry), at: Date())
        try journal.recordOperation(intentID: recorded.id, operationID: "op-1", status: .recorded, at: Date())
        let applied = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard, action: .resume), at: Date())
        try journal.recordOperation(intentID: applied.id, operationID: "op-2", status: .applied, at: Date())
        let foreign = try journal.recoverOrInsert(makeIntent(dashboardID: other), at: Date())

        try journal.clearDashboard(dashboard)

        // Resolved entries are retired; pending and recorded intents survive.
        XCTAssertNil(journal.entry(intentID: applied.id))
        XCTAssertNotNil(journal.entry(intentID: pending.id))
        XCTAssertNotNil(journal.entry(intentID: recorded.id))
        // Other dashboards are untouched.
        XCTAssertNotNil(journal.entry(intentID: foreign.id))
        // The survivors are exactly the dashboard's unresolved intents.
        let survivors = journal.unresolvedEntries(dashboardID: dashboard)
        XCTAssertEqual(Set(survivors.map { $0.intent.id }), [pending.id, recorded.id])
    }

    func testAbandonUnresolvedIntentsRemovesPendingAndRecorded() throws {
        var journal = RoomControlJournal(storageDirectory: dir)
        let dashboard = UUID()
        let pending = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard), at: Date())
        let recorded = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard, action: .retry), at: Date())
        try journal.recordOperation(intentID: recorded.id, operationID: "op-1", status: .recorded, at: Date())
        let applied = try journal.recoverOrInsert(makeIntent(dashboardID: dashboard, action: .resume), at: Date())
        try journal.recordOperation(intentID: applied.id, operationID: "op-2", status: .applied, at: Date())

        try journal.abandonUnresolvedIntents(dashboardID: dashboard)

        XCTAssertNil(journal.entry(intentID: pending.id))
        XCTAssertNil(journal.entry(intentID: recorded.id))
        // Resolved entries are unaffected by abandonment.
        XCTAssertNotNil(journal.entry(intentID: applied.id))
    }

    // MARK: - P1-3: durability and fail-closed commits

    func testIntentSurvivesReinstantiationWithSameIdempotencyKey() throws {
        // Kill/relaunch simulation: a NEW journal value over the same
        // directory recovers the same intent and idempotency key.
        let dashboard = UUID()
        let first = makeIntent(dashboardID: dashboard)
        do {
            var journal = RoomControlJournal(storageDirectory: dir)
            _ = try journal.recoverOrInsert(first, at: Date())
            try journal.recordOperation(
                intentID: first.id,
                operationID: "op-9",
                status: .recorded,
                at: Date()
            )
        }
        var relaunch = RoomControlJournal(storageDirectory: dir)
        XCTAssertEqual(relaunch.loadState, .healthy)
        let recovered = try relaunch.recoverOrInsert(
            makeIntent(dashboardID: dashboard).replacingIdentity(of: first),
            at: Date()
        )
        XCTAssertEqual(recovered.id, first.id)
        XCTAssertEqual(recovered.idempotencyKey, first.idempotencyKey)
    }

    func testFailedCommitThrowsAndLeavesInMemoryStateUntouched() throws {
        // A storage directory that is a FILE makes every commit fail:
        // the throw must surface and no entry may be staged in memory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomControlJournalTests.file.\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var journal = RoomControlJournal(storageDirectory: file)
        XCTAssertEqual(journal.loadState, .absent)
        let candidate = makeIntent()
        do {
            _ = try journal.recoverOrInsert(candidate, at: Date())
            XCTFail("recoverOrInsert must throw when the commit fails")
        } catch let error as RoomControlJournal.JournalError {
            if case .persistenceFailed = error {
                // Expected.
            } else {
                XCTFail("expected .persistenceFailed, got \(error)")
            }
        }
        XCTAssertNil(journal.entry(intentID: candidate.id))
        XCTAssertFalse(journal.isPoisoned)
    }
}

private extension RoomControlIntent {
    /// Returns a NEW intent (fresh id + correlation drift) that is
    /// semantically identical to `original` for idempotency recovery.
    func replacingIdentity(of original: RoomControlIntent) -> RoomControlIntent {
        RoomControlIntent(
            id: UUID(),
            dashboardID: original.dashboardID,
            roomID: original.roomID,
            executionID: original.executionID,
            action: original.action,
            attentionKind: original.attentionKind,
            trigger: original.trigger,
            projectSlug: original.projectSlug,
            correlationID: UUID().uuidString,
            idempotencyKey: "conduit:test:drifted-key"
        )
    }
}
