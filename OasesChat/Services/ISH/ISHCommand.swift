import Foundation

/// A single command submitted to the device-local iSH runtime.
struct ISHCommand: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let command: String
    let timeout: TimeInterval
    let environment: [String: String]
    /// Engineering session id — stamps iSH fs_context for /var/oases routing.
    let sessionId: String?

    init(
        id: UUID = UUID(),
        command: String,
        timeout: TimeInterval = 300,
        environment: [String: String] = [:],
        sessionId: String? = nil
    ) {
        self.id = id
        self.command = command
        self.timeout = max(0, timeout)
        self.environment = environment
        self.sessionId = sessionId
    }
}
