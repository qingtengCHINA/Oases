#if DEBUG
import Foundation

/// Base64 blobs that `DebugServer` serves from `GET /skill` and
/// `/skill/examples/{python,node,bash}` — the JSON-RPC protocol manual plus
/// ready-to-run client scripts.
///
/// In OpenMinis this file is *generated at build time* (`Generated/`) from the
/// checked-in skill markdown; it isn't in the repo, so there is nothing to
/// port. The constants are empty here, which is a case `DebugServer` already
/// handles explicitly: `sendSkill` returns `503 skill not embedded in this
/// build` and `sendSkillClient` does the same. Everything else on the debug
/// server — the JSON-RPC endpoint itself — is unaffected.
///
/// To enable these endpoints, add a build phase that writes this file with the
/// real base64 payloads, matching OpenMinis' generator.
enum DebugSkillGenerated {
    static let skillMarkdownB64 = ""
    static let clientPythonB64 = ""
    static let clientNodeB64 = ""
    static let clientBashB64 = ""
}
#endif
