//
//  AskHermesPromptViewTests.swift
//  Conduit
//
//  Deterministic coverage for the Copy Prompt confirmation race: when a
//  second copy tap replaces the confirmation task, SwiftUI cancels the
//  first task's sleep — and that cancellation must NOT clear the second
//  tap's fresh confirmation. The sleep is injected, so both outcomes are
//  exercised without real timers.
//

import XCTest
@testable import Conduit

final class AskHermesPromptViewTests: XCTestCase {
    func testCancelledConfirmationWindowDoesNotClearCopied() async {
        // The real cancellation mechanism: the window's own Task.sleep is
        // cancelled mid-sleep (as SwiftUI does when a second tap replaces
        // the task). Deterministic — cancellation during the sleep always
        // throws, so no timing is involved.
        var cleared = false
        let window = Task {
            await AskHermesPromptView.runCopiedConfirmation(
                duration: .seconds(3600),
                onExpire: { cleared = true }
            )
        }
        window.cancel()
        await window.value
        XCTAssertFalse(
            cleared,
            "A cancelled confirmation task must not clear the replacement tap's fresh confirmation"
        )
    }

    func testPostSleepCancellationGuardPreventsClearingCopied() async {
        // Case 2, distinct from the throwing-sleep test above: the injected
        // sleep completes SUCCESSFULLY after the surrounding task was already
        // cancelled, so execution passes the do/catch and reaches the
        // post-sleep `Task.isCancelled` guard. Removing that guard makes this
        // test fail. The fake sleep suspends on a continuation so the
        // cancel-before-resume ordering is fully deterministic.
        let suspension = SleepSuspension()
        let entered = expectation(description: "fake sleep suspended")
        var cleared = false

        let window = Task {
            await AskHermesPromptView.runCopiedConfirmation(
                // The fake sleep ignores its duration — cancellation ordering,
                // not timing, is what this test controls.
                duration: .seconds(2),
                sleep: { _ in
                    await withCheckedContinuation { continuation in
                        suspension.suspend(continuation)
                        entered.fulfill()
                    }
                },
                onExpire: { cleared = true }
            )
        }

        await fulfillment(of: [entered], timeout: 5)
        window.cancel()
        // Fail loudly instead of hanging if the sleep never suspended.
        XCTAssertTrue(suspension.isSuspended, "fake sleep must be suspended before cancel/resume")
        suspension.resume()
        await window.value

        XCTAssertFalse(
            cleared,
            "A cancelled task whose sleep completed successfully must still not clear the newer confirmation"
        )
    }

    func testUncancelledConfirmationWindowClearsCopiedOnExpiry() async {
        // The active (uncancelled) confirmation task is the only thing that
        // may reset `copied`, and it does so when its window expires.
        var cleared = false
        await AskHermesPromptView.runCopiedConfirmation(
            duration: .seconds(0),
            onExpire: { cleared = true }
        )
        XCTAssertTrue(
            cleared,
            "An uncancelled confirmation task must clear the copied flag on expiry"
        )
    }
}

/// Lock/continuation glue so the fake sleep can suspend deterministically
/// until the test chooses to resume it after cancelling the window task.
private final class SleepSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func suspend(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
