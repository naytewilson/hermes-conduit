# Session identity and recovery

Investigated against Conduit `2605ee95b907de067e05d0c914a865fab03a05ff` and the reporter's Hermes `9dd6634c5635321cf38840cc30e9b51226689128`. Updated 2026-09-06 to describe the shipped architecture (PR #137 branch `fix/session-identity-134`, commit `532b5b3` and successors).

## Problem and evidence

Issue #134 describes a quick second send after a completed reply leaving a canonical Bot Mode conversation. Local ordering debt causes a persisted-tail read, which can escalate to preserve-current synchronization. That synchronization replaces the catalog before resolving the selected runtime ID. The resolver falls back to an unrelated chat when the runtime alias is absent, and the caller creates a new session when no target exists. Only running turns retain a catalog row; the reported race is after settlement.

Resume also discards `stored_session_id` / `session_key` supplied by Hermes, then admits the returned runtime ID into presentation identity. Scroll identity, catalog matching, composer ownership and persistence each infer equivalence separately. Exact composer-ID checks can reject a submission after a legitimate runtime rebind.

## Delivered model: `ConversationIdentity`

`Conduit/Services/ConversationIdentity.swift` defines the authoritative identity value with a mandatory semantic separation:

- `profile` — the owning workspace profile.
- `durableSessionID: String?` — the stable UI/persistence identity (a catalog row's stored id, or the id the resume store persisted). Present only when positively established; a runtime-only conversation has none.
- `runtimeSessionID: String?` — the Hermes routing identity the gateway currently answers to. Rotation (`runtime-old` → `runtime-new`) is a transport rebind of the same conversation, never navigation.
- `acceptedSessionIDs: Set<String>` — every identifier POSITIVELY confirmed equivalent at capture time. It is captured BEFORE a recovery replaces the catalog and is never reconstructed from the replacement catalog afterward (catalog absence is not identity evidence).

`resumeTargetID` prefers the durable id when resuming. The value is a capture/admission model that projects into the existing systems (reconciliation accepted sets, scroll identity, resume store, composer ownership); it does not replace the viewport controller, turn-state machine, or catalog architecture.

### Resume identity parsing and admission

`SessionResumeResult` now parses `stored_session_id` / `session_key` separately into `storedSessionId` (nil on legacy gateways). `ConversationIdentityGate.admit(claim:selected:catalog:)` validates a `ResumeIdentityClaim` before any adoption:

1. Explicit durable identity matching the selected durable id → accept (`durableIdentityMatch`).
2. Returned id already a positively confirmed alias → accept (`knownAlias`). This covers mixed-generation catalogs that label the durable id differently while meaning the same row.
3. Returned runtime id positively owned by a different catalog row → reject (`foreignRuntimeOwnership`).
4. Explicit durable contradiction (a different, unconfirmed durable id) → reject (`durableContradiction`).
5. Legacy/unknown runtime rebind with no durable claim and no conflicting owner → accept (`legacyRuntimeRebind`) — the historical behavior, unchanged.

A rejected claim mutates nothing conversation-owned: no `activeSessionId`, selected conversation identity, transcript, scroll canonical identity, conversation persistence key, composer ownership, presentation cache, or resume-store selected identity may adopt the returned claim; the reconciliation settles, an error is surfaced, and the flow fails without navigating. The refreshed session catalog itself is independent discovery state and is NOT rolled back — a rejection blocks adoption, not discovery. A runtime-only conversation receiving its first stored key has that durable id ESTABLISHED (recorded as `resolvedDurableSessionId`), mirroring the create path.

### Runtime-to-durable persistence migration

When admission establishes or confirms a durable id, the canonical session key can move (runtime-solo → stored-solo) before any catalog row carries the new durable id. `migrateChatResumePersistenceIfNeeded` therefore has two evidence paths: the catalog path (unchanged — the row's id set proves which previous runtime key belongs to the conversation) and an admission path that keys off `resolvedDurableSessionId` plus the reconciliation's accepted alias set. Both route through `chatResumeCoordinator.migrateSessionIdentity(from:to:)` — one persistence system, no parallel store. The migration is conversation-scoped (only the conversation's previous canonical key moves) and profile-scoped (the coordinator requires a same-profile key pair). Without this, the first durable-establishing resume would strand the viewport snapshot under the runtime key while restoration looked under the durable key, silently falling back to latest.

## Invariants

- Recovery cannot select another conversation or create one when a current identity exists; catalog omission is not navigation authority.
- With NO current identity, preserve-current keeps the historical selection: newest ordinary chat, and `session.create` on an empty catalog (review finding 1; the pre-PR regression is reverted).
- Durable conversation identity and runtime routing identity have separate meanings, both in the model and in the resume parser.
- The accepted alias set is captured before catalog replacement (review finding 2); stream events addressed to a forgotten-but-confirmed alias stay buffered against the reconciliation and replay after the transcript replacement instead of being erased.
- A contradictory or foreign-owned resume identity is rejected before transcript, cache or active identity adoption; the catalog refresh itself is discovery state and stays published.
- Runtime rotation rebinds routing state only: the selected durable conversation, canonical identity, and resume store entry stay stable; old and new runtime ids become confirmed aliases. When the rotation establishes the durable key, the runtime-keyed scroll snapshot and resume-store entry migrate to the durable key even before a catalog row confirms it.
- Composer submissions survive a legitimate runtime rebind when every ownership fence still matches (same profile, client, client epoch, viewport transition generation, and durable conversation identity). Exact session-ID matches obey the same durable fence: routing-string equality is checked strictly (equal durable ids, or one catalog row positively containing both), because catalog re-attribution can keep the runtime string while re-homing the conversation. A switch away and back (A → B → A) is a handoff — each explicit open bumps the viewport generation — and invalidates suspended work even though the durable id matches again.
- Existing automatic latest/initial selection (Continue Where I Left Off, Jump to Latest Activity), explicit new/open/branch/archive/delete operations, busy input policies and transcript ordering checks are unchanged; destructive navigation still clears the identity and preserve-current recovery cannot resurrect a deleted conversation.

## Composer projection

`ComposerSubmissionContext` carries `durableSessionID` alongside the session id. `isCurrentComposerSubmission` never shortcuts ownership: exact session-ID matches must still prove durable ownership strictly (equal durable ids, or one catalog row positively containing both — alias-history bridges are excluded because catalog re-attribution pollutes exactly that history), and non-exact matches go through the shared alias path (`currentComposerSubmissionContextIfOwnedAndAliased`), which enforces the ownership fences plus a durable-identity defense-in-depth check. A captured nil session (pristine canvas) only stays valid while no session was selected since.

## Validation and limits

Regression coverage (see the implementation plan for results): the #134 second-send debt path, empty catalog, missing runtime alias with mid-resume event survival, no-current-identity fallback pins, durable contradiction rejection, foreign runtime rejection, legitimate rotation with routing rebind, composer rebind acceptance, composer handoff rejection, automatic-return policy pins, and deleted-conversation non-resurrection.

Known limits, documented deliberately:

- A runtime rotation that completes AFTER the prompt RPC is already dispatched still targets the old runtime id; delivery then flows through the existing ambiguous-submission recovery rather than pre-send re-addressing.
- Rebound runtime ids are not written back into catalog rows; the scroll identity and accepted sets carry them until the next catalog refresh confirms the row.
- An unlabeled catalog row's primary id is treated as its durable identity (the legacy catalog shape exposes the durable ID as `id`). For the rare hybrid skew — a `session_id`-only row that later receives a labeled resume — that manufactured durable turns a legitimate first labeling into a rejection. The reverse choice (durable only when labeled) was considered and declined: it would make preserve-current resume the runtime alias for the common legacy shape, resurfacing issue #134. A self-referential scroll canonical (canonical == selected id) is explicitly NOT durable evidence, so runtime-only conversations keep the establishment path.
- The live Feishu/Caddy/Tailscale deployment from issue #134 was unavailable; verification is deterministic-harness based.

No commits, pushes, PR creation or release steps are authorized by this task's repository instructions.
