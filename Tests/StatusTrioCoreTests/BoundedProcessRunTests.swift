import XCTest
@testable import StatusTrioCore

/// The deadline is what keeps a wedged system tool from pinning the calling
/// queue forever, so every recovery path is exercised against a real process:
/// a clean exit, a launch failure, the kill at the deadline, and the SIGKILL
/// escalation for a tool that ignores the termination request.
final class BoundedProcessRunTests: XCTestCase {
    func testCapturesStdoutFromAProcessThatExitsInTime() {
        let data = BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["bounded-run-payload"],
            timeout: .seconds(10)
        )

        XCTAssertEqual(
            String(data: data ?? Data(), encoding: .utf8),
            "bounded-run-payload\n"
        )
    }

    func testALaunchFailureReturnsNil() {
        XCTAssertNil(BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/no-such-status-trio-helper"),
            arguments: [],
            timeout: .seconds(1)
        ))
    }

    func testAProcessThatOutlivesItsDeadlineIsKilled() {
        let started = ContinuousClock.now

        let data = BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: .milliseconds(200)
        )

        XCTAssertNil(data, "a killed run must not read as a successful read")
        XCTAssertLessThan(
            ContinuousClock.now - started,
            .seconds(5),
            "the deadline must end the run instead of waiting out the process"
        )
    }

    func testPartialOutputFromAKilledRunIsDiscarded() {
        // `exec` replaces the shell, so the deadline's signal reaches the one
        // child and no orphan is left holding the pipe's write end.
        let data = BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo partial; exec sleep 30"],
            timeout: .milliseconds(200)
        )

        XCTAssertNil(data, "a killed run's partial report must not parse as a complete one")
    }

    func testAProcessThatIgnoresTerminationIsKilledAfterTheGracePeriod() {
        let started = ContinuousClock.now

        // `trap '' TERM` makes the shell ignore the deadline's first signal, so
        // only the SIGKILL escalation can end this run.
        let data = BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: .milliseconds(200),
            killGrace: .milliseconds(300)
        )

        XCTAssertNil(data)
        XCTAssertGreaterThan(
            ContinuousClock.now - started,
            .milliseconds(400),
            "the run must last through the grace period rather than dying at the deadline"
        )
        XCTAssertLessThan(
            ContinuousClock.now - started,
            .seconds(5),
            "the kill grace must end the run shortly after the deadline"
        )
    }

    func testANonZeroExitReturnsNilEvenWithOutput() {
        let data = BoundedProcessRun.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo discarded; exit 2"],
            timeout: .seconds(10)
        )

        XCTAssertNil(data)
    }
}
