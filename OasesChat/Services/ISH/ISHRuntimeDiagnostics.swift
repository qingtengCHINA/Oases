import Foundation

struct ISHRuntimeDiagnostics: Codable, Equatable, Sendable {
    private(set) var submitted = 0
    private(set) var started = 0
    private(set) var exited = 0
    private(set) var failed = 0
    private(set) var timedOut = 0
    private(set) var cancelled = 0
    private(set) var runtimeNotReady = 0
    private(set) var processCreationFailed = 0
    private(set) var execFailed = 0
    private(set) var active = 0
    private(set) var maxConcurrent = 0
    private(set) var serializedViolations = 0

    var terminal: Int {
        exited + failed + timedOut + cancelled + runtimeNotReady + processCreationFailed + execFailed
    }

    mutating func recordSubmission() {
        submitted += 1
    }

    mutating func recordStart() {
        started += 1
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        // Concurrent shells are expected (OpenMinis-aligned). `serializedViolations`
        // is reserved for true ownership bugs (e.g. double-complete); not concurrent peaks.
    }

    mutating func recordStartFailure(_ termination: ISHCommandTermination) {
        switch termination {
        case .runtimeNotReady:
            runtimeNotReady += 1
        case .processCreationFailed:
            processCreationFailed += 1
        case .execFailed:
            execFailed += 1
        default:
            failed += 1
        }
    }

    mutating func recordTerminal(_ termination: ISHCommandTermination) {
        switch termination {
        case .exited:
            exited += 1
        case .cancelled:
            cancelled += 1
        case .timedOut:
            timedOut += 1
        case .runtimeNotReady:
            runtimeNotReady += 1
        case .processCreationFailed:
            processCreationFailed += 1
        case .execFailed:
            execFailed += 1
        case .failed:
            failed += 1
        }
        if active > 0 {
            active -= 1
        }
    }
}

struct ISHRuntimeStressSelfTestReport: Equatable, Sendable {
    let requested: Int
    let completed: Int
    let uniqueCommandIDs: Int
    let maxConcurrent: Int
    let serializedViolations: Int
    let passed: Bool
}

