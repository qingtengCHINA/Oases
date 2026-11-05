import Foundation

enum ISHCommandTermination: String, Codable, Equatable, Sendable {
    case exited
    case cancelled
    case timedOut
    case runtimeNotReady
    case processCreationFailed
    case execFailed
    case failed
}

/// The value returned to an agent after the command has reached a terminal
/// state. `termination` is intentionally separate from `exitCode`: a command
/// can exit with a non-zero code without being cancelled or timed out.
struct ISHCommandResult: Codable, Equatable, Sendable {
    let commandID: UUID
    let command: String
    let pid: Int32?
    let exitCode: Int32?
    let termination: ISHCommandTermination
    let stdout: String
    let stderr: String
    let startedAt: Date?
    let endedAt: Date

    var succeeded: Bool {
        termination == .exited && exitCode == 0
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

