# Session identity implementation plan

**Goal:** Make preserve-current recovery retain conversation ownership through catalog gaps and runtime rebinding, on one authoritative conversation-identity model.

**Spec:** `docs/superpowers/specs/2026-09-06-session-identity-design.md`

**Architecture (as delivered):** `ConversationIdentity` (`Conduit/Services/ConversationIdentity.swift`) is the capture/admission model; AppState projects it into the existing reconciliation accepted sets, scroll identity, resume store and composer ownership. No turn-state, viewport-controller, transcript-ordering or catalog rewrite.

**Constraints:** Preserve unrelated work. ZCode has no `ios_test` tool; the equivalent verified path is a temp git worktree on ios-mac (git bundle for unpushed commits), `xcodegen generate`, `xcodebuild test` with an iPhone 17 Pro destination. Commits stay local until the architecture and regression suite are complete; nothing is merged.

- [x] Establish isolated Windows and Mac workspaces and run baseline resume suites.
- [x] Add policy, AppState recovery and second-send regression tests before implementation.
- [x] Add `ConversationIdentity.swift` with the durable/runtime/accepted-alias separation and `ConversationIdentityGate` resume admission.
- [x] Parse `stored_session_id` / `session_key` into `SessionResumeResult.storedSessionId` separately from the runtime id; reject contradictory or foreign-owned resume identities before any adoption, and establish a first stored key for runtime-only conversations.
- [x] Capture the complete selected identity (durable, runtime, accepted aliases) BEFORE recovery replaces the catalog; the preserve-current branch resumes it directly and buffered-delta dedup uses the captured set (review finding 2).
- [x] Restore the preserve-current no-current-identity boundary: newest-chat selection, `session.create` on empty catalog (review finding 1).
- [x] Record runtime rebinds as routing state (`resolvedDurableSessionId` projected into the scroll identity resolver and resume store) so rotation never looks like navigation.
- [x] Rebind composer context only under the existing profile/client/epoch/viewport fences plus a durable-identity check; pin that A → B → A handoffs still invalidate.
- [x] Regression matrix: #134 second-send debt path, empty catalog, missing runtime alias (with mid-resume event survival), no current identity, legitimate rotation, contradictory resume, foreign runtime, composer rebind, composer handoff, automatic-return pins, delete/no-resurrection.
- [x] Run focused red/green checks, existing lifecycle/handoff suites, full unit suite, UI suite, CI planner/inventory validation, script tests, `git diff --check` (results below).
- [x] Review the final diff (three-model review) and document actual results, remaining limitations and PR readiness.
- [x] Round 2 (post-CI hardening, same architecture): migrate runtime-keyed scroll/resume persistence to an admitted durable key without requiring a catalog row (admission-evidence path through `migrateSessionIdentity`); extend the durable composer fence to exact session-ID matches (strict proven ownership); restate the rejection invariant precisely (conversation adoption blocked, catalog discovery state not rolled back); regression tests for migration (plain and rotating), exact-ID/durable-mismatch rejection, fresh-context controls on both composer paths.

## Verification results

Recorded at commit time in the PR description; all suites listed above ran green on the Mac worktree (full ConduitTests suite, UI suite, planner validation, script tests). See the PR comment for per-suite counts.

## Remaining limitations

Documented in the spec ("Validation and limits"): post-dispatch rotation flows through ambiguous-delivery recovery, rebound aliases are not written back into catalog rows, and live-environment reproduction was unavailable.
