import Foundation

private final class ISHInteractiveSessionHandle: @unchecked Sendable {
    let session: ISHShellInteractiveSession

    init(_ session: ISHShellInteractiveSession) {
        self.session = session
    }
}

#if DEBUG
enum ISHInteractiveSessionSelfTest {
    static func run() async -> String {
        let startResult: (ISHInteractiveSessionHandle?, String?) = ISHRuntimeQueue.sync {
            guard ish_runtime_is_ready() != 0 || ISHRuntimeBootstrap.bootstrap() else {
                return (nil, "iSH runtime is not ready")
            }
            do {
                let session = try ISHShellInteractiveSession.startExecutable(
                    "/bin/sh",
                    arguments: ["-c", "printf 'interactive-ready\\n'; IFS= read -r line; printf 'interactive-received:%s\\n' \"$line\""],
                    environment: nil
                )
                return (ISHInteractiveSessionHandle(session), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        guard let handle = startResult.0 else {
            return "interactive_selftest=failed phase=start reason=\(startResult.1 ?? "unknown")"
        }

        let first = await Task.detached(priority: .utility) {
            handle.session.readStdoutLine(withTimeout: 5)
        }.value
        guard first == "interactive-ready" else {
            ISHRuntimeQueue.sync { handle.session.terminate(withSignal: 9) }
            return "interactive_selftest=failed phase=first_read value=\(first ?? "nil")"
        }

        let wrote = ISHRuntimeQueue.sync {
            handle.session.write(Data("hello-from-host\n".utf8))
        }
        let second = await Task.detached(priority: .utility) {
            handle.session.readStdoutLine(withTimeout: 5)
        }.value
        ISHRuntimeQueue.sync { handle.session.terminate(withSignal: 9) }

        guard wrote, second == "interactive-received:hello-from-host" else {
            return "interactive_selftest=failed phase=roundtrip wrote=\(wrote) value=\(second ?? "nil")"
        }
        return "interactive_selftest=ok phase=roundtrip"
    }
}
#endif

/// Persistent STDIO transport for MCP servers inside the embedded iSH rootfs.
///
/// Every server is launched once with iSH's fake TTY and all JSON-RPC messages
/// use that same guest process. There is intentionally no shell-pipeline,
/// tail/file cursor, or one-shot fallback in this data plane. Provisioning is
/// handled separately by the runtime profile service before this transport is
/// created.
actor ISHMCPStdioTransport: MCPStdioTransport {
    private let configuration: MCPConfiguration
    private let secretStore: MCPSecretStore
    private var processID: Int32?
    private var interactiveSession: ISHInteractiveSessionHandle?
    private var started = false

    init(
        configuration: MCPConfiguration,
        secretStore: MCPSecretStore = MCPSecretStore()
    ) {
        self.configuration = configuration
        self.secretStore = secretStore
    }

    func start() async throws {
        guard let command = configuration.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw ISHMCPStdioTransportError.missingCommand
        }
        if started { return }

        let ready = ISHRuntimeQueue.sync { ish_runtime_is_ready() != 0 }
        guard ready else {
            throw ISHMCPStdioTransportError.launchFailed(
                "iSH runtime is not ready; wait for the runtime service bootstrap to complete."
            )
        }
        let environment = try configuration.resolvedEnvironment(using: secretStore)
        try startInteractiveSession(environment: environment, command: command)
    }

    private func startInteractiveSession(
        environment: [String: String],
        command: String
    ) throws {
        let startResult: (ISHInteractiveSessionHandle?, String?) = ISHRuntimeQueue.sync {
            do {
                let session = try ISHShellInteractiveSession.startExecutable(
                    command,
                    arguments: self.configuration.arguments,
                    environment: environment
                )
                return (ISHInteractiveSessionHandle(session), nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        guard let handle = startResult.0 else {
            throw ISHMCPStdioTransportError.launchFailed(
                startResult.1 ?? "iSH interactive MCP session failed to launch."
            )
        }
        interactiveSession = handle
        processID = Int32(handle.session.pid)
        started = true
        if ProcessInfo.processInfo.environment["OASES_ISH_TRACE_STDIO"] == "1" {
            NSLog("[ISHMCP] persistent interactive launch pid=%d command=%@", handle.session.pid, command)
        }
    }

    func write(_ data: Data) async throws {
        guard started else { throw ISHMCPStdioTransportError.notRunning }
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw ISHMCPStdioTransportError.invalidPayload
        }
        guard let handle = interactiveSession else {
            throw ISHMCPStdioTransportError.writeFailed("iSH interactive session is unavailable.")
        }
        let wrote = ISHRuntimeQueue.sync { handle.session.write(data) }
        if ProcessInfo.processInfo.environment["OASES_ISH_TRACE_STDIO"] == "1" {
            NSLog("[ISHMCP] persistent interactive write bytes=%d completed=%@", data.count, wrote ? "yes" : "no")
        }
        guard wrote else {
            throw ISHMCPStdioTransportError.writeFailed("iSH interactive session stdin is closed.")
        }
    }

    func read() async throws -> Data? {
        guard started else { throw ISHMCPStdioTransportError.notRunning }
        guard let handle = interactiveSession else {
            throw ISHMCPStdioTransportError.processExited
        }
        let line = await Task.detached(priority: .utility) {
            handle.session.readStdoutLine(withTimeout: 70)
        }.value
        if ProcessInfo.processInfo.environment["OASES_ISH_TRACE_STDIO"] == "1" {
            NSLog("[ISHMCP] persistent interactive read received=%@", line ?? "nil")
        }
        // nil is EOF/timeout; an empty string is just a blank line on stdout
        // (the framer skips it), not the server exiting.
        guard let line else {
            throw ISHMCPStdioTransportError.processExited
        }
        return Data((line + "\n").utf8)
    }

    func stop() async {
        guard let handle = interactiveSession else {
            processID = nil
            started = false
            return
        }
        ISHRuntimeQueue.sync {
            handle.session.terminate(withSignal: 15)
        }
        interactiveSession = nil
        processID = nil
        started = false
    }
}

enum ISHMCPStdioTransportError: LocalizedError, Equatable, Sendable {
    case missingCommand
    case notRunning
    case invalidPayload
    case launchFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case responseTimeout
    case processExited
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingCommand: return "Persistent MCP STDIO session has no command."
        case .notRunning: return "Persistent MCP STDIO session is not running."
        case .invalidPayload: return "MCP STDIO payload is not valid UTF-8."
        case .launchFailed(let detail): return "MCP STDIO session failed to launch: \(detail)"
        case .writeFailed(let detail): return "MCP STDIO session write failed: \(detail)"
        case .readFailed(let detail): return "MCP STDIO session read failed: \(detail)"
        case .responseTimeout: return "MCP STDIO session did not produce a response before the timeout."
        case .processExited: return "MCP STDIO server exited before responding."
        case .emptyResponse: return "MCP STDIO session returned an empty response."
        }
    }
}
