import Foundation
@testable import Oases_Chat

enum ToolFixtures {
    static func completedArtifactCall(
        filename: String = "engineering-result.docx",
        path: String = "/tmp/Ogent Artifacts/engineering-result.docx"
    ) -> ToolCall {
        ToolCall(
            id: "fixture-artifact",
            name: "artifact_bridge",
            displayName: "Artifacts",
            description: "Fixture artifact",
            status: .completed,
            inputJSON: #"{"action":"create_docx"}"#,
            output: "Created DOCX: \(filename)\nios=\(path)\n[oases:open]\(path)",
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
    }

    static func failedCall() -> ToolCall {
        ToolCall(
            id: "fixture-failed",
            name: "web_browse",
            displayName: "Browse",
            status: .error,
            output: "NSURLErrorDomain -1001 timeout"
        )
    }
}
