import XCTest
@testable import Conduit

@MainActor
final class BotModeTests: XCTestCase {
    // MARK: - profiles.list decoding

    func testRosterDecoderExtractsBotFieldsFromProfilesListPayload() throws {
        let payload: [String: AnyCodable] = [
            "profiles": .array([
                .object([
                    "name": .string("atlas"),
                    "display_name": .string("Atlas"),
                    "description": .string("Research agent"),
                    "model": .string("hermes-4"),
                    "provider": .string("nous"),
                    "is_default": .bool(false),
                    "has_avatar": .bool(true),
                    "ui_meta": .object([
                        "hermes-bots": .object([
                            "title": .string("Scout"),
                            "pinned": .bool(true),
                            "hidden": .bool(false),
                            "color": .string("teal")
                        ])
                    ]),
                    "canonical_session": .object([
                        "id": .string("stored-1"),
                        "resolved_id": .string("runtime-1"),
                        "last_active": .number(1_700_000_000),
                        "preview": .string("Working on it")
                    ]),
                    "last_session": .object([
                        "last_active": .number(1_700_000_500),
                        "preview": .string("Newest human chat")
                    ])
                ])
            ]),
            "bot_mode_protocol": .bool(true)
        ]

        let snapshot = try XCTUnwrap(BotRosterDecoder.decode(.object(payload)))

        XCTAssertTrue(snapshot.supportsBotProtocol)
        XCTAssertEqual(snapshot.bots.count, 1)
        let bot = try XCTUnwrap(snapshot.bots.first)
        XCTAssertEqual(bot.name, "atlas")
        XCTAssertEqual(bot.displayLabel, "Scout", "the customized bot title outranks the profile display name")
        XCTAssertEqual(bot.profileDescription, "Research agent")
        XCTAssertEqual(bot.model, "hermes-4")
        XCTAssertTrue(bot.hasAvatar)
        XCTAssertTrue(bot.isPinned)
        XCTAssertEqual(bot.canonicalSession?.id, "stored-1")
        XCTAssertEqual(bot.canonicalSession?.resolvedID, "runtime-1")
        XCTAssertEqual(bot.canonicalSession?.preview, "Working on it")
        XCTAssertEqual(bot.lastActive, 1_700_000_500)
    }

    func testRosterDecodeFallsBackToDisplayNameAndToleratesMissingCanonical() throws {
        let payload: [String: AnyCodable] = [
            "profiles": .array([
                .object([
                    "name": .string("default"),
                    "display_name": .string("Default Profile")
                ])
            ])
        ]

        let snapshot = try XCTUnwrap(BotRosterDecoder.decode(.object(payload)))

        XCTAssertFalse(snapshot.supportsBotProtocol, "an older gateway omits the protocol flag")
        let bot = try XCTUnwrap(snapshot.bots.first)
        XCTAssertEqual(bot.displayLabel, "Default Profile")
        XCTAssertNil(bot.canonicalSession)
    }

    func testRosterDecodeRejectsNonProfilesEnvelope() {
        XCTAssertNil(BotRosterDecoder.decode(.object(["error": .string("nope")])))
    }

    func testDisplayOrderPinsFirstThenSortsByActivityThenName() {
        let pinned = makeBot(name: "pinned", pinned: true, canonicalLastActive: 10)
        let fresh = makeBot(name: "fresh", canonicalLastActive: 500)
        let older = makeBot(name: "older", canonicalLastActive: 100)
        let plainA = makeBot(name: "aaa", lastActive: 5)
        let plainB = makeBot(name: "bbb", lastActive: 5)

        let ordered = BotProfile.displayOrder([plainB, plainA, older, fresh, pinned])

        XCTAssertEqual(ordered.map(\.name), ["pinned", "fresh", "older", "aaa", "bbb"])
    }

    // MARK: - canonical-chat lookup rows

    func testLookupRowMatchesCanonicalTitleThroughRootTitlePrecedence() {
        XCTAssertTrue(BotChatLookupRow(id: "s1", title: "Bot Chat").isCanonicalTitle())
        XCTAssertTrue(
            BotChatLookupRow(id: "s1", title: "Drifted", rootTitle: "Bot Chat").isCanonicalTitle(),
            "the durable lineage-root title wins over the listing title"
        )
        XCTAssertFalse(BotChatLookupRow(id: "s1", title: "Project planning").isCanonicalTitle())
        XCTAssertFalse(
            BotChatLookupRow(id: "s1", rootTitle: "Project planning").isCanonicalTitle(),
            "a plain-title match must not override a different root title"
        )
    }

    func testLookupRowResumeTargetPrefersResolvedTip() {
        XCTAssertEqual(BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1").resumeTargetID, "runtime-1")
        XCTAssertEqual(BotChatLookupRow(id: "stored-1").resumeTargetID, "stored-1")
        XCTAssertEqual(BotChatLookupRow(id: "stored-1", resolvedID: "  ").resumeTargetID, "stored-1")
    }

    // MARK: - fail-closed resolution

    func testResolverOpensExistingCanonicalChatWithLineageTip() throws {
        let rows = [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "stored-1", resumeID: "runtime-1")
        )
    }

    func testResolverCreatesOnlyOnConfirmedAbsence() throws {
        let resolution = BotChatResolver.resolve(rows: [], rosterCanonicalID: nil)

        XCTAssertEqual(try resolution.get(), .create)
    }

    func testResolverFailsClosedWhenEmptyLookupContradictsRosterCanonical() {
        // The roster positively confirms this profile HAD a canonical chat;
        // an empty lookup answer is unconfirmed absence (a mid-restart
        // profile backend can answer successfully and empty). Minting here
        // is the forever-chat fork.
        let resolution = BotChatResolver.resolve(rows: [], rosterCanonicalID: "stored-1")

        XCTAssertEqual(resolution, .failure(.unconfirmedAbsence))
    }

    func testResolverFailsClosedWhenLookupFindsOnlyForeignTitles() {
        let rows = [BotChatLookupRow(id: "stored-9", title: "Bot Chatty")]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(resolution, .failure(.unconfirmedAbsence))
    }

    // MARK: - adopt-before-mint classification

    func testTitleCollisionClassifierMatchesGatewayRejection() {
        XCTAssertTrue(BotChatTitleCollision.isError(RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session x")))
        XCTAssertTrue(BotChatTitleCollision.isError(RpcError(code: 5000, message: "Title 'Bot Chat' is already in use by session x")))
        XCTAssertFalse(BotChatTitleCollision.isError(RpcError(code: 5000, message: "database is locked")))
        XCTAssertFalse(BotChatTitleCollision.isError(RpcError(code: -32601, message: "unknown method")))
    }

    // MARK: - gateway missing-method classification

    func testMissingMethodClassifierCoversProfilesListGap() {
        XCTAssertTrue(HermesClient.isMissingRPCMethod(RpcError(code: -32601, message: "unknown method")))
        XCTAssertTrue(HermesClient.isMissingRPCMethod(RpcError(code: nil, message: "method not found")))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(RpcError(code: 4001, message: "session not found")))
        XCTAssertFalse(HermesClient.isMissingRPCMethod(RpcError(code: 5000, message: "state.db is locked")))
    }

    // MARK: - sessions-list hygiene

    func testHygieneHidesCanonicalRegistryAndTipRows() {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-1")
        let registryRow = makeSessionSummary(id: "stored-1", title: "Bot Chat")
        let tipRow = makeSessionSummary(id: "runtime-1", title: "Bot Chat", storedID: "stored-1")
        let titledStaleRow = makeSessionSummary(id: "stray-1", title: "Bot Chat", profile: "atlas")

        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(registryRow, roster: [bot]))
        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(tipRow, roster: [bot]))
        XCTAssertTrue(BotChatHygiene.isCanonicalBotChatRow(titledStaleRow, roster: [bot]))
    }

    func testHygieneNeverHidesOrdinarySessions() {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1", resolvedID: "runtime-1")
        // A user conversation that merely shares the canonical title on the
        // dashboard profile stays visible: hidden + exact title is the
        // canonical discriminator, the title alone is not.
        let dashboardTitled = makeSessionSummary(id: "user-1", title: "Bot Chat", profile: "default")
        // An ordinary bot-profile session with a different title is a real
        // conversation and stays visible.
        let botProfileSession = makeSessionSummary(id: "bot-work-1", title: "Project planning", profile: "atlas")
        // A session matching nothing is untouched.
        let unrelated = makeSessionSummary(id: "user-2", title: "Groceries")

        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(dashboardTitled, roster: [bot]))
        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(botProfileSession, roster: [bot]))
        XCTAssertFalse(BotChatHygiene.isCanonicalBotChatRow(unrelated, roster: [bot]))
    }

    func testActiveProfileSessionsProjectionDropsCanonicalButKeepsCatalog() async {
        let bot = makeBot(name: "atlas", canonicalID: "stored-1")
        let canonicalRow = makeSessionSummary(id: "stored-1", title: "Bot Chat")
        let ordinaryRow = makeSessionSummary(id: "ordinary", title: "Design review")

        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                BotRosterSnapshot(bots: [bot], supportsBotProtocol: true)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [canonicalRow, ordinaryRow]

        // Seeding the roster through the probe path must project the
        // canonical row out of the Sessions list...
        await harness.appState.refreshBotRoster()

        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
        XCTAssertEqual(harness.appState.botModePhase, .available)
        XCTAssertEqual(harness.appState.activeProfileSessions.map(\.id), ["ordinary"])
        // ...while the identity machinery's catalog still sees the row:
        // the filter is presentation hygiene, never discovery.
        XCTAssertEqual(harness.appState.sessions.map(\.id), ["stored-1", "ordinary"])
    }

    // MARK: - open flow: fail-closed and identity semantics

    func testLookupFailureDoesNotCreateAndSurfacesRetryError() async {
        var createCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            findBotChat: { _, _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0, "a failed registry lookup must never mint a chat")
        XCTAssertNil(harness.appState.activeSessionId)
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertEqual(harness.appState.botModePhase, .idle, "an ordinary lookup failure is not a gateway gap")
    }

    func testMissingMethodLookupMarksGatewayUnsupportedWithoutCreating() async {
        var createCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            findBotChat: { _, _ in
                throw RpcError(code: -32601, message: "unknown method")
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0)
        XCTAssertEqual(harness.appState.botModePhase, .gatewayUnsupported)
    }

    func testUnconfirmedAbsenceRefusesToCreate() async throws {
        var createCalls = 0
        let rosterBot = makeBot(name: "atlas", canonicalID: "stored-1")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
            },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        let bot = try XCTUnwrap(harness.appState.botRoster.first)

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertFalse(opened)
        XCTAssertEqual(createCalls, 0, "empty lookup while the roster confirms a canonical chat must not mint")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testExistingCanonicalOpensResolvedTipThroughOrdinaryResume() async {
        var created = 0
        var resumedIDs: [String] = []
        var resumeProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedIDs.append(id)
                resumeProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            },
            createBotChat: { _, _ in
                created += 1
                return ("runtime-x", nil)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(created, 0)
        XCTAssertEqual(resumedIDs, ["runtime-1"], "the open addresses the compression-lineage tip")
        XCTAssertEqual(resumeProfiles, ["atlas"], "the resume rides the BOT profile, never the dashboard scope")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, "atlas", "the bot's display label titles the chat")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testMissingCanonicalCreatesHiddenTitledChatThenOpensRuntime() async {
        var order: [String] = []
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                order.append("open:\(profile ?? "nil")")
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                order.append("lookup")
                return []
            },
            createBotChat: { _, profile in
                order.append("create:\(profile)")
                return ("runtime-new", "stored-new")
            },
            titleBotChat: { _, sessionID, title, profile in
                order.append("title:\(sessionID):\(title):\(profile)")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(
            order.first, "lookup",
            "the registry lookup always precedes creation"
        )
        XCTAssertTrue(order.contains("create:atlas"))
        XCTAssertTrue(
            order.contains("title:runtime-new:\(BotMode.canonicalChatTitle):atlas"),
            "the eager title names the bot profile it addresses"
        )
        XCTAssertTrue(
            (order.firstIndex { $0.hasPrefix("open:") } ?? order.endIndex) > (order.firstIndex { $0.hasPrefix("title:") } ?? 0),
            "the open only happens after the canonical title landed"
        )
        XCTAssertEqual(order.last, "open:atlas", "the open resumes under the BOT's profile scope")
        XCTAssertEqual(resumedIDs, ["runtime-new"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new")
    }

    func testCreationTitleCollisionAdoptsWinnerInsteadOfForking() async {
        var createCalls = 0
        var lookups = 0
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-winner",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookups += 1
                // First consultation: confirmed absence. Second (post-collision
                // adoption re-lookup): another writer holds the canonical row.
                return lookups == 1
                    ? []
                    : [BotChatLookupRow(id: "stored-winner", resolvedID: "runtime-winner", title: "Bot Chat")]
            },
            createBotChat: { _, _ in
                createCalls += 1
                return ("runtime-stray", nil)
            },
            titleBotChat: { _, _, _, _ in
                throw RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session stored-winner")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(createCalls, 1, "the stray lazy session is created once and then abandoned")
        XCTAssertEqual(lookups, 2, "the collision re-consults the registry")
        XCTAssertEqual(resumedIDs, ["runtime-winner"], "the winner's lineage tip is opened, never our stray")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-winner")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testTitleFailureOtherThanCollisionFailsClosedWithoutOpening() async {
        var openCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                openCalls += 1
                return SessionResumeResult(
                    sessionId: "runtime-stray",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in ("runtime-stray", nil) },
            titleBotChat: { _, _, _, _ in
                throw RpcError(code: 5000, message: "state.db is locked")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertFalse(opened)
        XCTAssertEqual(openCalls, 0, "an untitled lazy row must never be opened: the registry has no entry yet")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testBotOpenDoesNotSeedTheColdRestoreResumeStore() async {
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.store.setLastSessionID("ordinary-previous", for: "default")

        _ = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertEqual(
            harness.store.lastSessionID(for: "default"),
            "ordinary-previous",
            "a bot chat is not the dashboard workspace's selected conversation"
        )
    }

    func testConcurrentBotOpensShareOneFlight() async {
        var lookupCalls = 0
        var resumeCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, id, _ in
                resumeCalls += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookupCalls += 1
                return [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        async let first: Bool = harness.appState.openBotChat(for: bot)
        async let second: Bool = harness.appState.openBotChat(for: bot)
        let (firstResult, secondResult) = await (first, second)

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(lookupCalls, 1, "double-tapping a row must not consult the registry twice")
        XCTAssertEqual(resumeCalls, 1)
    }

    func testRosterRefreshDropsStaleResponseAfterServerIdentityChange() async {
        // The seam captures the state by box so the response can race the
        // outgoing server's teardown: by the time it lands,
        // prepareChatResumeForConnection has already bumped the epoch.
        var capturedState: AppState?
        let staleBot = makeBot(name: "stale-bot")
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                botRoster: { _ in
                    _ = capturedState?.prepareChatResumeForConnection(
                        to: "https://elsewhere.example",
                        dashboardID: UUID()
                    )
                    return BotRosterSnapshot(bots: [staleBot], supportsBotProtocol: true)
                }
            )
        )
        capturedState = harness.appState
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await harness.appState.refreshBotRoster()

        XCTAssertEqual(
            harness.appState.botRoster.map(\.name), [],
            "a roster answer captured under an older epoch must never describe the new server"
        )
        XCTAssertEqual(harness.appState.botModePhase, .idle)
    }

    func testResolverPinsRosterCanonicalAmongLegacyForks() throws {
        let rows = [
            BotChatLookupRow(id: "stray-1", title: "Bot Chat"),
            BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")
        ]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "stored-1")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "stored-1", resumeID: "runtime-1"),
            "the roster's server-resolved registry breaks ties among legacy forks"
        )
    }

    func testResolverFallsBackToFirstCanonicalWhenRosterPinMisses() throws {
        let rows = [
            BotChatLookupRow(id: "a-1", title: "Bot Chat"),
            BotChatLookupRow(id: "b-1", title: "Bot Chat")
        ]

        let resolution = BotChatResolver.resolve(rows: rows, rosterCanonicalID: "not-present")

        XCTAssertEqual(
            try resolution.get(),
            .openExisting(registryID: "a-1", resumeID: "a-1"),
            "a pin that matches none of the forks falls back to the listing order"
        )
    }

    // MARK: - PR #170 review triage regressions

    func testLookupDecoderRejectsAnyMalformedRowInsteadOfDiscarding() {
        // A conforming gateway always emits non-empty ids, but the decoder
        // is the identity registry: one malformed row makes the WHOLE
        // lookup unreliable, and an unreliable lookup must read as failure —
        // never as confirmed absence (which is what authorizes minting).
        let payload: [String: AnyCodable] = [
            "sessions": .array([
                .object([
                    "id": .string("stored-1"),
                    "title": .string("Bot Chat")
                ]),
                // Structurally malformed: no id at all.
                .object([
                    "title": .string("Bot Chat")
                ])
            ])
        ]

        XCTAssertNil(
            BotChatLookupDecoder.decode(.object(payload)),
            "a malformed row must fail the whole lookup, never shrink it"
        )
    }

    func testLookupDecoderRejectsNonDictionaryRow() {
        let payload: [String: AnyCodable] = [
            "sessions": .array([
                .string("not-a-row")
            ])
        ]

        XCTAssertNil(BotChatLookupDecoder.decode(.object(payload)))
    }

    func testSupersededRosterRefreshDoesNotClearNewerRefreshClaim() async {
        // Boxes the two seam invocations can poll from the test body.
        final class Gate: @unchecked Sendable {
            var open = false
        }
        let releaseFirst = Gate()
        var calls = 0
        let rosterBot = makeBot(name: "atlas")
        let staleBot = makeBot(name: "stale-bot")
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                botRoster: { _ in
                    calls += 1
                    if calls == 1 {
                        while !releaseFirst.open {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        return BotRosterSnapshot(bots: [staleBot], supportsBotProtocol: true)
                    }
                    // The newer refresh holds the claim long enough for the
                    // superseded one to finish and (wrongly) release it.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let first = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        // Server switch: bumps the epoch and resets the single-flight flag.
        _ = harness.appState.prepareChatResumeForConnection(
            to: "https://elsewhere.example",
            dashboardID: UUID()
        )
        let second = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(
            harness.appState.isRefreshingBotRoster,
            "the newer refresh owns the single-flight claim"
        )

        releaseFirst.open = true
        await first.value
        XCTAssertTrue(
            harness.appState.isRefreshingBotRoster,
            "the superseded refresh completing must NOT clear the newer refresh's claim"
        )
        await second.value
        XCTAssertFalse(harness.appState.isRefreshingBotRoster)
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
    }

    func testSupersededSameSessionBotOpenStaysSilent() async {
        // While the bot open is mid-resume, a newer ordinary open of the
        // SAME session id takes over the viewport. The superseded bot open
        // completes afterwards and must stay silent: supersession is
        // navigation state, not an error.
        final class Gate: @unchecked Sendable {
            var open = false
        }
        let releaseBotResume = Gate()
        var resumeCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                resumeCalls += 1
                if resumeCalls == 1 {
                    while !releaseBotResume.open {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let botOpen = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.openBotChat(for: bot)
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        // A newer navigation re-opens the SAME session id through the
        // ordinary path; it takes over the viewport transition.
        _ = await harness.appState.openSession("runtime-1")
        releaseBotResume.open = true

        let opened = (await botOpen.value) ?? false

        XCTAssertEqual(resumeCalls, 2)
        XCTAssertFalse(
            opened,
            "the superseded open did not complete — the newer navigation owns the viewport"
        )
        XCTAssertNil(
            harness.appState.errorMessage,
            "a superseded bot open is navigation state, never an error"
        )
    }

    // MARK: - review-hardening regressions

    func testStrayCatalogRowDoesNotBlockCanonicalOpen() async {
        // A visible stray row for the canonical chat (older server data) sits
        // in the raw catalog under the BOT's profile. The ordinary workspace
        // guard protects dashboard opens; a bot open carries its own profile
        // and must proceed through the ordinary machinery anyway.
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedIDs.append(id)
                _ = profile
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        harness.appState.sessions = [
            makeSessionSummary(id: "runtime-1", title: "Bot Chat", storedID: "stored-1", profile: "atlas")
        ]

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened, "a stray cross-profile catalog row must not block the canonical open")
        XCTAssertEqual(resumedIDs, ["runtime-1"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testCreateCollisionAdoptsWinnerInsteadOfForking() async {
        var createCalls = 0
        var lookups = 0
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-winner",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                lookups += 1
                return lookups == 1
                    ? []
                    : [BotChatLookupRow(id: "stored-winner", resolvedID: "runtime-winner", title: "Bot Chat")]
            },
            // Some gateways enforce the canonical name at create time.
            createBotChat: { _, _ in
                createCalls += 1
                throw RpcError(code: 4022, message: "Title 'Bot Chat' is already in use by session stored-winner")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(createCalls, 1)
        XCTAssertEqual(lookups, 2, "a create-time collision re-consults the registry")
        XCTAssertEqual(resumedIDs, ["runtime-winner"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-winner")
        XCTAssertNil(harness.appState.errorMessage)
    }

    func testRefreshFailureWithEstablishedRosterSurfacesNotice() async {
        var calls = 0
        let rosterBot = makeBot(name: "atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                calls += 1
                if calls == 1 {
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
                throw RpcError(code: 5000, message: "gateway restart in progress")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        await harness.appState.refreshBotRoster()
        XCTAssertEqual(harness.appState.botModePhase, .available)

        await harness.appState.refreshBotRoster()

        guard case .failed(let message) = harness.appState.botModePhase else {
            return XCTFail("a failed refresh over an established roster must surface the notice phase")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(
            harness.appState.botRoster.map(\.name), ["atlas"],
            "the stale roster stays visible under the failure notice"
        )
    }

    func testServerSwitchCancelsInFlightBotOpen() async {
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                defaults.set(
                    "https://one.example",
                    forKey: "conduit.chatResumeServerIdentity.v1"
                )
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSessionWithProfile: { _, id, _, _ in
                    // The flight is mid-resume when the server switches.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        async let opened: Bool = harness.appState.openBotChat(for: bot)
        try? await Task.sleep(nanoseconds: 60_000_000)
        _ = harness.appState.prepareChatResumeForConnection(
            to: "https://elsewhere.example",
            dashboardID: UUID()
        )
        let result = await opened

        XCTAssertFalse(result, "a server switch must abandon the in-flight bot open")
        XCTAssertNil(
            harness.appState.errorMessage,
            "an abandoned flight stays silent: the refusal text describes the outgoing server"
        )
        XCTAssertEqual(
            harness.appState.activeSessionId, nil,
            "the stale flight must not navigate the UI against the outgoing server"
        )
        XCTAssertTrue(harness.appState.botRoster.isEmpty)
        XCTAssertEqual(harness.appState.botModePhase, BotModePhase.idle)
    }

    func testBackfillWindowCarriesBotProfileScope() async {
        var hydrationProfiles: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, _ in
                SessionResumeResult(
                    sessionId: id,
                    storedSessionId: "stored-1",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, profile, _ in
                hydrationProfiles.append(profile)
                // A full tail-anchored page (echoed order=latest, limit ==
                // rawReturned) so the window stamp runs and the backfill
                // affordance arms.
                var rows: [[String: Any]] = []
                for index in 0..<PersistedTranscriptPagination.pageSize {
                    rows.append([
                        "id": "row-\(index)",
                        "role": "user",
                        "content": "row \(index)",
                        "timestamp": String(index)
                    ])
                }
                return .payload([
                    "session_id": sessionId,
                    "messages": rows,
                    "pagination": [
                        "limit": PersistedTranscriptPagination.pageSize,
                        "offset": 0,
                        "order": "latest",
                        "returned": PersistedTranscriptPagination.pageSize
                    ]
                ])
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertTrue(opened)
        XCTAssertEqual(hydrationProfiles, ["atlas"], "the persisted-history hydration addresses the bot profile")
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.profile, "atlas",
            "the backfill window is stamped with the bot scope so older pages fetch from the bot's store"
        )
        XCTAssertTrue(
            harness.appState.canLoadEarlierMessagesForActiveConversation,
            "the ownership gate must accept the bot-scoped window while the chat is active"
        )
    }

    func testCreateStageGenericFailureFailsClosedWithoutOpening() async {
        var openCalls = 0
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, _, _, _ in
                openCalls += 1
                return SessionResumeResult(
                    sessionId: "runtime-stray",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in [] },
            createBotChat: { _, _ in
                throw RpcError(code: 5000, message: "profile backend unavailable")
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let opened = await harness.appState.openBotChat(for: makeBot(name: "atlas"))

        XCTAssertFalse(opened)
        XCTAssertEqual(openCalls, 0, "a failed create never opens the lazy runtime")
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertEqual(harness.appState.botModePhase, BotModePhase.idle)
    }

    // MARK: - bot title-cache regressions

    /// Opens a canonical Bot Chat as the ACTIVE session and then refreshes
    /// the catalog, whose raw row is titled exactly "Bot Chat". Neither the
    /// visible label nor the PERSISTED ordinary active-title cache may pick
    /// the wire title up (the cold-restore bug).
    func testCatalogRefreshNeverPersistsBotChatTitleForActiveBotConversation() async {
        let harness = makeBotHarness(
            sessionCatalogLoader: { _ in
                [self.makeSessionSummary(
                    id: "runtime-1",
                    title: BotMode.canonicalChatTitle,
                    storedID: "stored-1",
                    profile: "default"
                )]
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, id, _ in
                    SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        let opened = await harness.appState.openBotChat(for: bot)

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, bot.displayLabel)

        await harness.appState.loadSessions()

        XCTAssertEqual(
            harness.appState.activeSessionTitle, bot.displayLabel,
            "the catalog's literal Bot Chat row must not displace the bot's display label"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the wire title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
    }

    /// A .sessionTitle event addressed to the canonical Bot Chat may update
    /// catalog rows, but must never overwrite the active bot label or
    /// persist the literal wire title into the ordinary cache.
    func testSessionTitleEventNeverPersistsBotChatTitleForActiveBotConversation() async {
        let harness = makeBotHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, id, _ in
                    SessionResumeResult(
                        sessionId: id,
                        storedSessionId: "stored-1",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")
        let opened = await harness.appState.openBotChat(for: bot)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")

        harness.appState.handleStreamEvent(
            .sessionTitle(runtimeSessionId: "runtime-1", storedSessionId: "stored-1", title: BotMode.canonicalChatTitle)
        )

        XCTAssertEqual(
            harness.appState.activeSessionTitle, bot.displayLabel,
            "the event must not overwrite the bot's display label"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the event title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
    }

    /// Ordinary (non-bot) sessions keep both title paths exactly as before.
    func testOrdinaryActiveSessionTitlesStillPersistThroughBothPaths() async {
        let harness = makeBotHarness(
            sessionCatalogLoader: { _ in
                [self.makeSessionSummary(id: "ordinary-1", title: "Fresh Catalog Title")]
            },
            lifecycleOperations: ChatResumeLifecycleOperations()
        )

        harness.appState.activeSessionId = "ordinary-1"
        await harness.appState.loadSessions()

        XCTAssertEqual(harness.appState.activeSessionTitle, "Fresh Catalog Title")
        var persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Fresh Catalog Title")

        harness.appState.handleStreamEvent(
            .sessionTitle(runtimeSessionId: "ordinary-1", storedSessionId: "stored-ordinary", title: "Event Title")
        )
        XCTAssertEqual(harness.appState.activeSessionTitle, "Event Title")
        persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Event Title")
    }

    /// The `.task(id:)` identity change cancels the VIEW task while its
    /// refresh is in flight. A replacement that only bails on the
    /// single-flight guard strands `.loading`: the cancelled holder releases
    /// the claim without committing a phase. The refresh now runs
    /// unstructured and late callers JOIN it, so the cancel can no longer
    /// kill the work and the roster still commits.
    func testRosterRefreshJoinKeepsPhaseAliveWhenCallerTaskIsCancelled() async {
        final class Gate: @unchecked Sendable {
            var open = false
        }
        let releaseFirst = Gate()
        var stubCalls = 0
        let rosterBot = makeBot(name: "atlas")
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            botRoster: { _ in
                stubCalls += 1
                if stubCalls == 1 {
                    // This await is the network boundary where a cancelled
                    // VIEW task used to kill the in-flight refresh.
                    try Task.checkCancellation()
                    while !releaseFirst.open {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    return BotRosterSnapshot(bots: [rosterBot], supportsBotProtocol: true)
                }
                return BotRosterSnapshot(bots: [], supportsBotProtocol: true)
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        let first = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        while !harness.appState.isRefreshingBotRoster {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let second = Task { @MainActor [weak harnessState = harness.appState] in
            await harnessState?.refreshBotRoster()
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
        first.cancel()
        releaseFirst.open = true
        await second.value
        await first.value

        XCTAssertEqual(
            harness.appState.botModePhase, .available,
            "a cancelled view task must not strand the roster on .loading"
        )
        XCTAssertEqual(harness.appState.botRoster.map(\.name), ["atlas"])
    }

    // MARK: - PR #170 triage: reserved-row resume boundary

    /// Cold launch has neither a roster nor a bot-chat registry entry, so the
    /// reserved exact title is the only signal that can keep a stale/legacy
    /// visible canonical row out of the ordinary automatic resume selection.
    /// The row must not become this workspace's active conversation (which is
    /// what seeds the cold-restore selection and persists the wire title),
    /// while the published catalog itself stays untouched.
    func testAutomaticResumeNeverSelectsReservedBotChatRow() async {
        let botChatRow = makeSessionSummary(
            id: "runtime-bot",
            title: BotMode.canonicalChatTitle,
            storedID: "stored-bot"
        )
        let ordinaryRow = makeSessionSummary(id: "ordinary-1", title: "Design review")
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [botChatRow, ordinaryRow] },
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        XCTAssertTrue(harness.appState.botRoster.isEmpty, "a cold launch carries no roster")

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertEqual(
            Set(resumedIDs),
            Set(["ordinary-1"]),
            "the reserved canonical row is never a resume candidate"
        )
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
        XCTAssertEqual(
            harness.store.lastSessionID(for: "default"),
            "ordinary-1",
            "the cold-restore selection belongs to the ordinary conversation, not the bot chat"
        )
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persisted?["default"], "Design review")
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "the reserved wire title must never enter the persisted ordinary title cache: \(persisted ?? [:])"
        )
        XCTAssertTrue(
            harness.appState.sessions.contains { $0.title == BotMode.canonicalChatTitle },
            "the filter is selection-only: the published catalog keeps the row"
        )
    }

    /// The reserved row is not a fallback either. When it is the only
    /// candidate, ordinary selection declines (the pre-existing "no eligible
    /// chat" behaviour) rather than adopting a bot's forever chat as this
    /// workspace's conversation. The resume seam is what makes the assertion
    /// meaningful: it proves the row was never even attempted, not that a
    /// failed resume happened to leave the state clean.
    func testAutomaticResumeDeclinesWhenOnlyCandidateIsReservedBotChat() async {
        let botChatRow = makeSessionSummary(
            id: "runtime-bot",
            title: BotMode.canonicalChatTitle,
            storedID: "stored-bot"
        )
        var resumedIDs: [String] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            loadCatalog: { _, _ in [botChatRow] },
            openSession: { _, id, _ in
                resumedIDs.append(id)
                return SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )

        await harness.appState.syncSession(
            purpose: .automaticReturn,
            using: nil,
            automaticWorkToken: nil
        )

        XCTAssertTrue(resumedIDs.isEmpty, "the reserved row is never resumed: \(resumedIDs)")
        XCTAssertNil(harness.appState.activeSessionId, "the reserved row is never adopted")
        XCTAssertNil(harness.store.lastSessionID(for: "default"))
        let persisted = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persisted?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "declining must not persist the reserved title either: \(persisted ?? [:])"
        )
    }

    /// A canonical Bot Chat known to the registry can still be opened through
    /// the ORDINARY path (`requestOpenSession` and friends pass no
    /// conversation profile). Ownership must therefore come from registry
    /// identity, so the raw catalog row titled "Bot Chat" never reaches the
    /// persisted ordinary title cache — while ordinary opens are unchanged.
    func testOrdinaryOpenOfRegistryKnownBotChatNeverPersistsWireTitle() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSessionWithProfile: { _, id, _, profile in
                resumedProfiles.append(profile)
                return SessionResumeResult(
                    sessionId: id,
                    storedSessionId: id == "runtime-1" ? "stored-1" : nil,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            findBotChat: { _, _ in
                [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
            }
        ))
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "default"
        )
        let bot = makeBot(name: "atlas")

        // The roster's own open registers the canonical conversation.
        let openedAsBot = await harness.appState.openBotChat(for: bot)
        XCTAssertTrue(openedAsBot)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(harness.appState.activeSessionTitle, bot.displayLabel)
        XCTAssertEqual(resumedProfiles, ["atlas"])

        // A stale/legacy visible canonical row sits in the raw catalog.
        harness.appState.sessions = [
            makeSessionSummary(
                id: "runtime-1",
                title: BotMode.canonicalChatTitle,
                storedID: "stored-1"
            )
        ]

        let reopenedOrdinary = await harness.appState.openSession("runtime-1")
        XCTAssertTrue(reopenedOrdinary, "a registry-known bot chat still opens through the ordinary path")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertNil(
            harness.store.lastSessionID(for: "default"),
            "an ordinary-path open of a bot conversation never claims the cold-restore selection"
        )
        XCTAssertEqual(
            harness.appState.activeSessionTitle,
            bot.displayLabel,
            "the reserved wire title never displaces the bot's display label"
        )
        let persistedAfterOrdinaryOpen = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertFalse(
            persistedAfterOrdinaryOpen?.values.contains(BotMode.canonicalChatTitle) ?? false,
            "ordinary opens of a bot conversation never persist the wire title: \(persistedAfterOrdinaryOpen ?? [:])"
        )

        // An ordinary conversation keeps persisting its title exactly as before.
        harness.appState.sessions = [
            makeSessionSummary(
                id: "runtime-1",
                title: BotMode.canonicalChatTitle,
                storedID: "stored-1"
            ),
            makeSessionSummary(id: "ordinary-1", title: "Design review")
        ]
        let openedOrdinary = await harness.appState.openSession("ordinary-1")
        XCTAssertTrue(openedOrdinary)
        XCTAssertEqual(harness.appState.activeSessionId, "ordinary-1")
        let persistedAfterOrdinarySession = lastHarnessDefaults?.dictionary(
            forKey: "conduit.activeSessionTitlesByProfile.v1"
        ) as? [String: String]
        XCTAssertEqual(persistedAfterOrdinarySession?["default"], "Design review")
    }

    /// A canonical Bot Chat's identity IS the exact title "Bot Chat", so it
    /// must never enter automatic title generation — a generated rename would
    /// break the exact-title lookup that resolves the profile's forever chat.
    /// Ordinary conversations keep the historical recovery scheduling.
    func testSecondaryTitleRecoveryNeverSchedulesForCanonicalBotChat() async {
        var resumedProfiles: [String?] = []
        let harness = makeBotHarness(
            configureDefaults: { defaults in
                // The recovery's own historical gate: it only runs for a
                // non-default workspace profile.
                defaults.set("analyst", forKey: "conduit.activeProfile")
            },
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSessionWithProfile: { _, id, _, profile in
                    resumedProfiles.append(profile)
                    return SessionResumeResult(
                        sessionId: id,
                        storedSessionId: id == "runtime-1" ? "stored-1" : nil,
                        messages: [
                            ChatMessage(id: "user-1", role: .user, content: "Question", timestamp: "1"),
                            ChatMessage(id: "assistant-1", role: .assistant, content: "Answer", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                findBotChat: { _, _ in
                    [BotChatLookupRow(id: "stored-1", resolvedID: "runtime-1", title: "Bot Chat")]
                }
            )
        )
        harness.appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
            profile: "analyst"
        )
        XCTAssertEqual(harness.appState.activeProfile, "analyst")

        let openedAsBot = await harness.appState.openBotChat(for: makeBot(name: "atlas"))
        XCTAssertTrue(openedAsBot)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-1")
        XCTAssertEqual(resumedProfiles, ["atlas"])
        XCTAssertFalse(
            harness.appState.hasSecondaryTitleRecoveryScheduled(forSessionID: "runtime-1"),
            "a canonical Bot Chat never enters automatic title recovery"
        )

        // Positive control: the same entry point still schedules for an
        // ordinary conversation, so the assertion above cannot be vacuous.
        harness.appState.sessions = [
            makeSessionSummary(id: "ordinary-1", title: "Design review", profile: "analyst")
        ]
        let openedOrdinary = await harness.appState.openSession("ordinary-1")
        XCTAssertTrue(openedOrdinary)
        XCTAssertTrue(
            harness.appState.hasSecondaryTitleRecoveryScheduled(forSessionID: "ordinary-1"),
            "ordinary conversations keep the historical title-recovery scheduling"
        )
    }

    // MARK: - harness

    /// The UserDefaults suite of the most recent harness, so tests can pin
    /// PERSISTED state (e.g. the active-session title cache), not just the
    /// visible string.
    private var lastHarnessDefaults: UserDefaults?

    private func makeBotHarness(
        configureDefaults: (UserDefaults) -> Void = { _ in },
        sessionCatalogLoader: ((Bool) async throws -> [SessionSummary])? = nil,
        lifecycleOperations: ChatResumeLifecycleOperations
    ) -> (appState: AppState, store: ChatResumeStore) {
        let suite = "BotModeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        lastHarnessDefaults = defaults
        configureDefaults(defaults)
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionCatalogLoader: sessionCatalogLoader,
            chatResumeLifecycleOperations: lifecycleOperations
        )
        appState.isConnected = true
        return (appState, store)
    }

    // MARK: - fixtures

    private func makeBot(
        name: String,
        pinned: Bool = false,
        canonicalID: String? = nil,
        resolvedID: String? = nil,
        canonicalLastActive: Double? = nil,
        lastActive: Double? = nil
    ) -> BotProfile {
        let resolvedCanonicalID = canonicalID
            ?? (canonicalLastActive != nil ? "stored-\(name)" : nil)
        return BotProfile(
            name: name,
            botTitle: nil,
            displayName: name,
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: pinned,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: resolvedCanonicalID.map { id in
                BotCanonicalSession(
                    id: id,
                    resolvedID: resolvedID,
                    lastActive: canonicalLastActive,
                    preview: nil
                )
            },
            lastActive: lastActive,
            lastPreview: nil
        )
    }

    private func makeSessionSummary(
        id: String,
        title: String,
        storedID: String? = nil,
        profile: String? = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
            alternateIds: [],
            title: title,
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
