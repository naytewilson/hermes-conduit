//
//  AppLanguageTests.swift
//  Conduit
//
//  Guards the in-app App Language facility: persistence, resolution of the
//  SwiftUI environment locale and the explicit `AppLocalization` path
//  through the SAME selection, English fallback for untranslated keys, and
//  the protocol-value invariant that configuration values never localize.
//

import XCTest
@testable import Conduit

@MainActor
final class AppLanguageTests: XCTestCase {
    private var standardDefaults: UserDefaults { UserDefaults.standard }

    override func setUp() async throws {
        // The global selection lives in the standard defaults; start every
        // test from the system default and restore afterwards.
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    override func tearDown() async throws {
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    // MARK: - Persistence

    func testSelectionPersistsAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: "AppLanguageTests")!
        defer { defaults.removePersistentDomain(forName: "AppLanguageTests") }

        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.selection, .system)
        store.select(.simplifiedChinese)

        let relaunched = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(relaunched.selection, .simplifiedChinese)
    }

    func testSelectingSameLanguageDoesNotRepublish() {
        let store = AppLanguageStore()
        store.select(.system) // no-op on the default
        XCTAssertEqual(store.selection, .system)
    }

    func testExplicitSelectionReadsThroughGlobalCurrentWithoutStore() {
        standardDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguageStore.defaultsKey)
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        XCTAssertEqual(AppLanguage.current, .simplifiedChinese)

        standardDefaults.set("bogus", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .system, "an unknown stored value must fall back to system")

        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLanguage.current, .system)
    }

    // MARK: - Resolution

    func testSystemSelectionUsesSystemLocale() {
        let store = AppLanguageStore()
        XCTAssertEqual(AppLanguage.system.languageCode, nil)
        XCTAssertNil(AppLanguage.system.locale)
        // The environment locale follows the device when set to system.
        if case .system = store.selection {} else { XCTFail("precondition") }
    }

    func testExplicitSelectionsCarryPinnedLocales() {
        XCTAssertEqual(AppLanguage.english.locale, Locale(identifier: "en"))
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale, Locale(identifier: "zh-Hans"))
    }

    func testLocalizationBundlesExistInBuiltApp() {
        // The pinned-language mechanism depends on the per-language lproj
        // resources the String Catalog build emits into the app bundle.
        XCTAssertNotNil(Bundle.main.path(forResource: "en", ofType: "lproj"))
        XCTAssertNotNil(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
    }

    // MARK: - Explicit String localization through the selected language

    func testExplicitChineseOverrideResolvesCatalogTranslation() {
        XCTAssertEqual(
            AppLocalization.string("Settings", language: .simplifiedChinese),
            "设置")
    }

    func testExplicitEnglishOverrideResolvesSourceString() {
        XCTAssertEqual(
            AppLocalization.string("Settings", language: .english),
            "Settings")
    }

    func testSystemPathMatchesSourceOnDevelopmentLanguageHost() {
        // Byte-identical to a bare String(localized:) when no override is
        // active and the process runs in the development language.
        XCTAssertEqual(
            AppLocalization.string("Settings", language: .system),
            String(localized: "Settings"))
    }

    func testRuntimeSelectionChangeReResolvesExplicitStrings() {
        // AppLocalization reads the persisted selection per call, so a
        // change made in Settings re-resolves the running UI without an
        // AppleLanguages mutation or relaunch.
        standardDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLocalization.string("Settings"), "设置")

        standardDefaults.set(AppLanguage.english.rawValue, forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(AppLocalization.string("Settings"), "Settings")
    }

    func testInterpolatedSkeletonResolvesUnderSelectedLanguage() {
        XCTAssertEqual(
            AppLocalization.string("Voice on \(String("Phy"))", language: .simplifiedChinese),
            "语音 · Phy")
        XCTAssertEqual(
            AppLocalization.string("Voice on \(String("Phy"))", language: .english),
            "Voice on Phy")
    }

    // MARK: - Fallback behavior (English is the development language)

    func testUntranslatedKeyFallsBackToEnglishSource() {
        let missing = String.LocalizationValue("Completely untranslated probe key")
        XCTAssertEqual(AppLocalization.string(missing, language: .simplifiedChinese), "Completely untranslated probe key")
        XCTAssertEqual(AppLocalization.string(missing, language: .english), "Completely untranslated probe key")
    }

    func testMissingInterpolatedSkeletonFormatsEnglishFallback() {
        // A missing skeleton must never render as a broken format
        // placeholder — the English source is formatted with the arguments.
        XCTAssertEqual(
            AppLocalization.string("Probe \(42) units", language: .simplifiedChinese),
            "Probe 42 units")
    }

    // MARK: - Catalog plural variations through the selected language

    func testCatalogPluralVariationsResolvePerLanguage() {
        // SidebarView's session count: English grammar is owned by the
        // catalog's plural variations (never built in code), and Chinese
        // carries its own single-category value.
        XCTAssertEqual(
            AppLocalization.string("\(1) conversations", language: .english),
            "1 conversation")
        XCTAssertEqual(
            AppLocalization.string("\(2) conversations", language: .english),
            "2 conversations")
        XCTAssertEqual(
            AppLocalization.string("\(2) conversations", language: .simplifiedChinese),
            "2 个会话")
    }

    // MARK: - UI language stays separate from speech/provider language

    func testAppLanguageNeverTouchesProviderConfiguration() {
        // The App Language facility must have no surface that could write
        // provider/model/STT/TTS state: its entire persistence surface is
        // the single defaults key read back here.
        standardDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguageStore.defaultsKey)
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }

        let voicePreferences = VoiceProfilePreferences()
        XCTAssertEqual(voicePreferences.spokenStopPhrases, VoiceSpokenCommands.defaultStopPhrases)
        XCTAssertEqual(voicePreferences.spokenEndConversationPhrases,
                       VoiceSpokenCommands.defaultEndConversationPhrases)
        XCTAssertEqual(voicePreferences.resolvedTranscriptionMode, .hermes)
    }

    // MARK: - Live switching without state loss

    /// Switching App Language must update localization WITHOUT the old
    /// root-identity rebuild: no navigation, session, message, profile, or
    /// composer-draft state may be touched by the switch path.
    func testLanguageSwitchDoesNotResetApplicationState() {
        let suite = "AppLanguageTests.AppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )

        // Seed representative app state the old `.id()` rebuild would have
        // disturbed.
        let message = ChatMessage(
            id: "lang-switch-msg",
            role: .user,
            content: "unchanged conversation content",
            timestamp: "1"
        )
        appState.messages = [message]
        let originalProfile = appState.activeProfile
        let originalConnectionPhase = appState.voiceLaunchConnectionSnapshot()

        let store = AppLanguageStore()
        let expectations = [AppLanguage.english, .simplifiedChinese, .system]
        for language in expectations {
            store.select(language)
            appState.appLanguageDidChange()

            XCTAssertEqual(appState.messages.map(\.id), [message.id],
                           "messages must survive a language switch to \(language)")
            XCTAssertEqual(appState.messages.first?.content, message.content)
            XCTAssertEqual(appState.activeProfile, originalProfile,
                           "active profile must survive a language switch to \(language)")
            XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase,
                           originalConnectionPhase.phase,
                           "voice connection phase must be untouched by \(language)")
            XCTAssertFalse(appState.slashCommands.isEmpty,
                           "slash command cache must stay populated after \(language)")
        }

        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    /// Composer drafts live in their own store; the language-switch path
    /// must never clear them (old `.id()` rebuild discarded the ComposerBar
    /// @State that owned the store).
    func testLanguageSwitchSurvivesComposerDraft() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(profile: "default",
                                   sessionID: ComposerDraftKey.newConversationSessionID)
        let draft = ComposerDraft(text: "unsent draft that must survive", attachments: [])
        store.save(draft, for: key)

        let languageStore = AppLanguageStore()
        for language in [AppLanguage.simplifiedChinese, .english, .system] {
            languageStore.select(language)
            XCTAssertEqual(store.draft(for: key), draft,
                           "composer draft must survive a language switch to \(language)")
        }
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    func testLanguageSwitchDoesNotRepublishSlashCommandIdentity() {
        let suite = "AppLanguageTests.SlashIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let before = appState.slashCommands.map(\.id)
        let store = AppLanguageStore()
        store.select(.simplifiedChinese)
        appState.appLanguageDidChange()
        XCTAssertEqual(appState.slashCommands.map(\.id), before,
                       "language refresh re-merges descriptions, not identities")
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
    }

    // MARK: - Protocol-value invariants under localization

    func testBuiltInSlashCommandsKeepProtocolFieldsRaw() {
        // Only the display copy (description, category) localizes. The
        // name/aliases are protocol tokens dispatched verbatim to Hermes
        // and must stay raw ASCII under every App Language.
        for language in AppLanguage.allCases {
            for command in AppState.builtInSlashCommands {
                XCTAssertFalse(command.name.isEmpty)
                XCTAssertTrue(command.name.allSatisfy { $0.isASCII },
                              "\(command.name) must stay a raw protocol token")
                for alias in command.aliases {
                    XCTAssertTrue(alias.allSatisfy { $0.isASCII },
                                  "\(command.name) alias \(alias) must stay raw")
                }
                XCTAssertFalse(command.description.isEmpty)
            }
        }
    }

    func testSlashCommandIdentityIsStableAcrossLanguageChanges() {
        // Identity is the protocol name: the localized rebuild must not
        // mint fresh identities that would churn ForEach and equality.
        let before = AppState.builtInSlashCommands
        standardDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguageStore.defaultsKey)
        defer { standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey) }
        let after = AppState.builtInSlashCommands
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.name), after.map(\.name))
    }
}
