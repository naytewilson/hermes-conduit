# ANVIL Mobile Control Surface Continuation

**Status:** ACTIVE UMBRELLA PROGRAM  
**Recovered:** 2026-09-18  
**Repository:** `naytewilson/hermes-conduit`  
**Source anchor:** `main@d3053d05eb1966a2caf321eef64ba15eecc1489d`

## Why this file exists

The ANVIL mobile-first program remained durable in Drive and its first Conduit Room client seam landed in source, but the umbrella program was not represented in the ANVIL Active Pointers index. Later controller continuations could therefore select lower-level SIEVE, Room, relay, or research campaigns without surfacing the mobile operator objective.

This file is a source-control continuation anchor. It does not replace ANVIL/Postgres authority, Drive evidence, or live runtime verification.

## Governing mission

Conduit is the native SwiftUI iPhone/iPad human control surface for ANVIL.

The larger system boundary remains:

- ANVIL/Postgres: durable operational authority.
- GitHub: committed source truth.
- Drive OS: evidence and continuity.
- Paseo Hub: orchestration and projection.
- Runner Fabric: execution placement.
- Local Agent Gateway: provider/model/session plane.
- SIEVE: evidence and context trust.
- LeanCTX: candidate context planning.
- Paseo + Conduit: human control surfaces.
- Tailscale: reachability only.

Reachability never grants authority.

## PROVEN current baseline

As of the recovery point above:

- PR #1 is merged into Conduit main.
- The merged Room seam contains:
  - `RoomModels`
  - `RoomProjectionClient`
  - `RoomReplayCoordinator`
  - `RoomReplayStore`
  - dashboard-scoped Room Hub credentials
  - focused Room tests
- Terminal Room Execution Fabric evidence reports:
  - full `ConduitTests`: 131 passed, 0 failed
  - live Hub Room replay: 14 committed events
  - durable cursor high-water: 15
  - legal sequence gap preserved
  - restart restore reproduced
  - second sync applied zero duplicate events
  - dashboard credential isolation preserved
- The Room seam is intentionally read-only.
- Real device/signing validation is still unproven because the build host did not have the required provisioning profile. Signing or entitlements must not be weakened to manufacture a green result.

All mutable claims must be re-verified before implementation.

## Product direction that must not disappear again

The target is not a read-only Room viewer.

The target is a native ANVIL cockpit where the operator can eventually inspect and, when explicitly authorized, control:

- Rooms and campaign timelines
- agents and execution bindings
- machines and runtime health
- evidence and verification state
- approvals and capability grants
- task/campaign state
- source/CI state where safely exposed

The mobile client must preserve the distinction between:

- observed/proven state
- agent-claimed state
- stale cached state
- inferred state
- authorized action state

## Next coherent product wave

Do not jump straight to broad machine administration.

After reacquiring current source truth, build the smallest useful capability-scoped control wave on top of the proven Room replay seam.

Candidate action family, subject to current server contracts:

1. Room message / steer
2. approve or deny an explicitly pending decision
3. interrupt or stop an owned execution
4. refresh/replay authoritative Room state after reconnect

The exact first action set is chosen only after verifying current ANVIL/Hub APIs and grants.

### Required architecture

```text
Conduit intent
    |
    v
explicit device/user capability
    |
    v
Hub / ANVIL authority check
    |
    v
idempotent server-side operation
    |
    v
durable Room / task / audit effect
    |
    v
replayable projection back to Conduit
```

The client must never infer authority from a visible button, network reachability, a cached token, or prior success.

## Mobile safety and UX gates

- Dashboard/device credentials remain narrowly scoped and Keychain-backed.
- Mutable actions fail closed when authority cannot be freshly established.
- Retries and reconnects cannot duplicate semantic effects.
- Dangerous actions use deliberate confirmation and biometric step-up where appropriate.
- Offline state remains useful but visibly stale and non-authoritative.
- State restoration survives app termination and network changes.
- APNs is a wake/deep-link mechanism, not an authority channel.
- Swift concurrency ownership must be explicit.
- Dynamic Type, VoiceOver, reduced motion, iPad size classes, keyboard navigation, and native interaction semantics are product requirements, not polish.
- No broad bearer bucket and no client-minted grants.

## Verification gates

Before calling the next mobile-control wave complete:

1. Re-query Conduit main, ANVIL main, current Hub projection/runtime, and capability schemas.
2. Preserve the existing read/replay test suite.
3. Add negative authority tests for every mutable action.
4. Add retry/reconnect/idempotency tests.
5. Exercise stale/offline behavior.
6. Run the full Conduit simulator suite.
7. Perform real signed-device validation without weakening entitlements or signing.
8. Bind the final result to exact source refs and durable receipts.

## Durable recovery sources

- Drive: `ANVIL_NERVOUS_SYSTEM_DAG_V1_1_20260914.md`
- Drive: `ANVIL_ROOM_EXECUTION_FABRIC_V1 — Final Battle Report`
- ANVIL Active Pointers:
  - `ANVIL_NERVOUS_SYSTEM_MOBILE_PROGRAM`
  - `CONDUIT_ANVIL_MOBILE_CLIENT`
- GitHub: Conduit PR #1 and merge `d3053d05eb1966a2caf321eef64ba15eecc1489d`

## Continuation rule

A completed infrastructure subcampaign does not close or supersede this umbrella product mission unless an explicit durable decision says so.

Fresh controller contexts must recover this program before selecting a mobile/operator next action.