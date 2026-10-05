import Darwin
import Foundation

/// Runs one external process to completion and bounds how long the run may
/// hold the calling queue.
///
/// Reading a subprocess's output is synchronous and cannot be cancelled, so a
/// wedged system tool would pin the calling serial queue forever — for the
/// CoreWLAN worker that means the Wi-Fi list never leaves `.scanning`, and for
/// the profiler workers it means every later read queues behind the stuck one.
/// Killing the process is the only way out: the signal closes the pipe's write
/// end, the blocked read reaches EOF, and the run unwinds. A tool that ignores
/// the termination request is killed outright once the grace period passes.
enum BoundedProcessRun {
    /// - Returns: The process's standard output when it launched, exited
    ///   successfully, and did so inside `timeout`. `nil` when it could not be
    ///   launched, was killed for outliving the deadline, or exited non-zero:
    ///   partial output from a killed run must never be mistaken for a
    ///   complete report.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        killGrace: Duration = .seconds(2)
    ) -> Data? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // The signals are sent from a side queue, because the calling thread is
        // blocked in the read below until EOF. Only `isRunning` is read there,
        // which is why the process goes through this box: `Process` is not
        // `Sendable`, and the read is the same primitive `terminationHandler`
        // already uses alongside a waiting `waitUntilExit`. `kill` is used
        // instead of `Process.terminate` so a signal that races the process's
        // own exit is a harmless failed syscall rather than a Foundation
        // exception.
        let launched = LaunchedProcess(process)
        let identifier = process.processIdentifier
        let termDeadline = DispatchTime.now() + Self.seconds(timeout)
        let killDeadline = termDeadline + Self.seconds(killGrace)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: termDeadline) {
            guard launched.process.isRunning else { return }
            kill(identifier, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: killDeadline) {
            guard launched.process.isRunning else { return }
            kill(identifier, SIGKILL)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// `Duration` has no built-in bridge to `DispatchTime`'s Double seconds.
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}

/// Teardown-owned storage for the deadline closures above: they may outlive
/// `run`'s stack (they hold the process until after the grace deadline) and
/// must keep it alive without retaining the run itself. They only read
/// `isRunning` from it.
private final class LaunchedProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
