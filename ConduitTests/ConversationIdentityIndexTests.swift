import XCTest
@testable import Conduit

@MainActor
final class ConversationIdentityIndexTests: XCTestCase {
    func testRecordAndLookupRoundTrip() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-a", profile: "default"), "stored-a")
    }

    func testSelfMappingCarriesNoInformation() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "same",
            durableID: "same",
            profile: "default",
            source: .create
        )
        XCTAssertNil(
            index.durableID(forRuntime: "same", profile: "default"),
            "A runtime id equal to its durable id needs no index entry"
        )
    }

    func testLookupNormalizesWhitespace() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "  runtime-a  ",
            durableID: " stored-a ",
            profile: " default ",
            source: .resume
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-a", profile: "default"), "stored-a")
    }

    func testMappingsAreProfileScoped() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-shared",
            durableID: "stored-in-default",
            profile: "default",
            source: .resume
        )
        XCTAssertNil(
            index.durableID(forRuntime: "runtime-shared", profile: "work"),
            "A runtime id from one profile must never establish ownership in another"
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-shared", profile: "default"), "stored-in-default")
    }

    func testConflictingEvidenceKeepsConfirmedMappingAndReportsConflict() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        let conflict = index.record(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .notification
        )

        XCTAssertEqual(
            conflict,
            ConversationIdentityIndex.IdentityConflict(
                runtimeID: "runtime-x",
                confirmedDurableID: "stored-a",
                incomingDurableID: "stored-b",
                source: .notification
            ),
            "A disagreeing positive claim is surfaced, never silently unioned"
        )
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-a",
            "The confirmed mapping stands until the authoritative catalog changes it"
        )
    }

    func testIdenticalEvidenceIsNotAConflict() {
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        XCTAssertNil(index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .catalog
        ))
        XCTAssertEqual(index.durableID(forRuntime: "runtime-x", profile: "default"), "stored-a")
    }

    func testAuthoritativeRecordEstablishesNewMapping() {
        let index = ConversationIdentityIndex()
        XCTAssertNil(index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .activeList
        ))
        XCTAssertEqual(index.durableID(forRuntime: "runtime-x", profile: "default"), "stored-a")
    }

    func testAuthoritativeRecordRebindsStaleConfirmedMapping() {
        // The exact split-brain case: the index holds a historical
        // runtime-x → stored-B mapping, but the app just ADMITTED a resume
        // proving runtime-x now routes to stored-A. Keeping the old mapping
        // would leave the selected conversation and the index disagreeing,
        // so the authoritative rebind wins and the displaced mapping is
        // returned for diagnostics.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .resume
        )
        let conflict = index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        XCTAssertEqual(
            conflict,
            ConversationIdentityIndex.IdentityConflict(
                runtimeID: "runtime-x",
                confirmedDurableID: "stored-b",
                incomingDurableID: "stored-a",
                source: .resume
            )
        )
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-a",
            "The app accepted the resume into conversation-owned state; the index must agree"
        )
    }

    func testNotificationEvidenceCannotOverwriteAuthoritativeMapping() {
        // A stale dual-ID push payload must not poison a fresher
        // authoritative mapping: navigation may attempt the payload's claim,
        // but the index keeps the live-registry truth.
        let index = ConversationIdentityIndex()
        index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .activeList
        )
        let conflict = index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .notification
        )
        XCTAssertNotNil(conflict)
        XCTAssertEqual(index.durableID(forRuntime: "runtime-x", profile: "default"), "stored-b")
    }

    func testActiveListRowsRebindLikeCatalogTruth() {
        // session.active_list is the live registry: its re-attribution has
        // the same authority as a catalog refresh.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        index.recordAuthoritative(
            runtimeID: "runtime-x",
            durableID: "stored-b",
            profile: "default",
            source: .activeList
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-x", profile: "default"), "stored-b")
    }

    func testCatalogReattributionOverwritesStaleConfirmedMapping() {
        // The live registry is the freshest authority on what a runtime id
        // routes to; the row's new stored id is a routing identity change.
        let index = ConversationIdentityIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: "default",
            source: .resume
        )
        index.recordCatalogIdentity(
            [makeSummary(id: "stored-b", stored: "stored-b", alternateIDs: ["runtime-x"])],
            profile: "default"
        )
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-b"
        )
    }

    func testCatalogEvidenceRecordsEveryLabeledRowAlias() {
        let index = ConversationIdentityIndex()
        index.recordCatalogIdentity(
            [
                makeSummary(id: "runtime-1", stored: "stored-1", alternateIDs: ["runtime-1b"]),
                makeSummary(id: "legacy-row", stored: nil, alternateIDs: ["legacy-alt"])
            ],
            profile: "default"
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-1", profile: "default"), "stored-1")
        XCTAssertEqual(index.durableID(forRuntime: "runtime-1b", profile: "default"), "stored-1")
        XCTAssertNil(
            index.durableID(forRuntime: "legacy-row", profile: "default"),
            "An unlabeled row's primary id is already its durable identity; the self-mapping is information-free"
        )
        XCTAssertNil(index.durableID(forRuntime: "legacy-alt", profile: "default"))
    }

    func testRemoveSessionIDsDropsMappingsByRuntimeOrDurable() {
        let index = ConversationIdentityIndex()
        index.record(runtimeID: "runtime-a", durableID: "stored-a", profile: "default", source: .resume)
        index.record(runtimeID: "runtime-a2", durableID: "stored-a", profile: "default", source: .resume)
        index.record(runtimeID: "runtime-b", durableID: "stored-b", profile: "default", source: .resume)

        index.removeSessionIDs(["stored-a"], profile: "default")
        XCTAssertNil(index.durableID(forRuntime: "runtime-a", profile: "default"))
        XCTAssertNil(index.durableID(forRuntime: "runtime-a2", profile: "default"))
        XCTAssertEqual(index.durableID(forRuntime: "runtime-b", profile: "default"), "stored-b")

        index.removeSessionIDs(["runtime-b"], profile: "default")
        XCTAssertNil(index.durableID(forRuntime: "runtime-b", profile: "default"))
    }

    func testRemoveSessionIDsIsProfileScoped() {
        let index = ConversationIdentityIndex()
        index.record(runtimeID: "runtime-a", durableID: "stored-a", profile: "default", source: .resume)
        index.record(runtimeID: "runtime-a", durableID: "stored-work", profile: "work", source: .resume)

        index.removeSessionIDs(["stored-a"], profile: "default")
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-a", profile: "work"),
            "stored-work",
            "Deletion in one profile must not revoke another profile's identity"
        )
    }

    func testRemoveAllDropsEveryProfile() {
        let index = ConversationIdentityIndex()
        index.record(runtimeID: "runtime-a", durableID: "stored-a", profile: "default", source: .resume)
        index.record(runtimeID: "runtime-b", durableID: "stored-b", profile: "work", source: .catalog)

        index.removeAll()
        XCTAssertNil(index.durableID(forRuntime: "runtime-a", profile: "default"))
        XCTAssertNil(index.durableID(forRuntime: "runtime-b", profile: "work"))
    }

    func testCatalogFirstRowWinsWithinOneSnapshotOverStaleMergedRow() {
        // The committed catalog can contain cached rows merged after fresh
        // ones, and routing reads the same order with `first(where:)` — so
        // the index must not pin a later stale row's re-attribution.
        let index = ConversationIdentityIndex()
        index.recordCatalogIdentity(
            [
                makeSummary(id: "stored-fresh", stored: "stored-fresh", alternateIDs: ["runtime-x"]),
                makeSummary(id: "stale-cache", stored: "stale-cache", alternateIDs: ["runtime-x"])
            ],
            profile: "default"
        )
        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: "default"),
            "stored-fresh",
            "The first (freshest) row in one snapshot decides, mirroring the resolver"
        )
    }

    func testCatalogSkipsRowsLabeledForAnotherProfile() {
        let index = ConversationIdentityIndex()
        index.recordCatalogIdentity(
            [
                makeSummary(id: "work-row", stored: "work-durable", alternateIDs: ["runtime-w"], profile: "work"),
                makeSummary(id: "default-row", stored: "default-durable", alternateIDs: ["runtime-d"], profile: nil)
            ],
            profile: "default"
        )
        XCTAssertNil(
            index.durableID(forRuntime: "runtime-w", profile: "default"),
            "A foreign-profile row must not commit into this profile's scope"
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-d", profile: "default"), "default-durable")
    }

    private func makeSummary(
        id: String,
        stored: String?,
        alternateIDs: [String],
        profile: String? = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: stored,
            alternateIds: alternateIDs,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}
