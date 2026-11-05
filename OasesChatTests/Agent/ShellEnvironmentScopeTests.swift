import XCTest
@testable import Oases_Chat

/// Security regression tests for per-command env var scoping
/// (ISHExecutionCoordinator → ShellEnvironmentScope): a prompt-injected
/// `env` / `printenv` must not receive the user's Keychain-backed secrets.
final class ShellEnvironmentScopeTests: XCTestCase {
    private let secrets = [
        "OPENAI_API_KEY": "sk-openai-0123456789abcdef",
        "TAVILY_API_KEY": "tvly-9876543210fedcba",
        "GITHUB_TOKEN": "ghp_aaaaaaaaaaaaaaaaaaaa",
    ]
    private var available: [String] { Array(secrets.keys) + ["PIP_INDEX_URL"] }
    private var skillsRoot: URL!

    override func setUpWithError() throws {
        skillsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-scope-\(UUID().uuidString)", isDirectory: true)
        let skill = skillsRoot.appendingPathComponent("tavily-search/scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "# Tavily\nRun scripts/search.py\n".write(
            to: skillsRoot.appendingPathComponent("tavily-search/SKILL.md"), atomically: true, encoding: .utf8)
        try "import os\nkey = os.environ.get(\"TAVILY_API_KEY\")\n".write(
            to: skill.appendingPathComponent("search.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: skillsRoot)
    }

    private func names(for command: String) -> Set<String> {
        ShellEnvironmentScope.scopedNames(for: command, available: available, skillsRoot: skillsRoot)
    }

    /// The environment a command would actually receive, in `env` format.
    private func envOutput(for command: String) -> String {
        let user = secrets.filter { names(for: command).contains($0.key) }
        let env = ISHExecutionCoordinator.toolchainEnvironment.merging(user) { _, new in new }
        let printed = env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        return ShellEnvironmentScope.redact(printed, secrets: ShellEnvironmentScope.redactableSecrets(in: user))
    }

    func testEnvAndPrintenvReceiveNoSecrets() {
        for command in ["env", "printenv", "env | base64", "cat /proc/self/environ", "set"] {
            let scoped = names(for: command)
            XCTAssertTrue(scoped.isDisjoint(with: secrets.keys), "\(command) got \(scoped)")
            let output = envOutput(for: command)
            for value in secrets.values {
                XCTAssertFalse(output.contains(value), "\(command) leaked a secret")
            }
        }
    }

    func testImplicitToolSettingsStillApply() {
        XCTAssertEqual(names(for: "pip install requests"), ["PIP_INDEX_URL"])
    }

    func testReferencedNameIsInjected() {
        XCTAssertTrue(names(for: "echo $OPENAI_API_KEY").contains("OPENAI_API_KEY"))
        XCTAssertTrue(names(for: "curl -H \"Authorization: Bearer ${GITHUB_TOKEN}\" x").contains("GITHUB_TOKEN"))
        XCTAssertTrue(names(for: "python3 -c 'import os; print(os.environ[\"OPENAI_API_KEY\"])'")
            .contains("OPENAI_API_KEY"))
        // Word boundaries: a longer identifier is a different variable.
        XCTAssertFalse(names(for: "echo $OPENAI_API_KEY_2 $XOPENAI_API_KEY").contains("OPENAI_API_KEY"))
        // Referencing one secret does not pull in the others.
        XCTAssertEqual(names(for: "echo $OPENAI_API_KEY"), ["OPENAI_API_KEY", "PIP_INDEX_URL"])
    }

    func testReferencedSecretIsMaskedInOutput() {
        let output = envOutput(for: "printenv OPENAI_API_KEY")
        XCTAssertFalse(output.contains(secrets["OPENAI_API_KEY"]!))
        XCTAssertTrue(output.contains("OPENAI_API_KEY=***"))
    }

    func testBase64WrappedScriptIsScanned() {
        // AIChatViewModel+ISHCommand hands bash scripts over as base64.
        let script = "curl -H \"Authorization: Bearer $OPENAI_API_KEY\" https://api.example.com\n"
        let b64 = Data(script.utf8).base64EncodedString()
        let command = "command -v bash >/dev/null 2>&1 || exit 119; printf %s '\(b64)' | base64 -d > /tmp/x.sh && bash /tmp/x.sh"
        XCTAssertTrue(names(for: command).contains("OPENAI_API_KEY"))
    }

    func testSkillScriptPathGetsDeclaredVar() {
        for command in [
            "python3 /var/minis/skills/tavily-search/scripts/search.py 'query'",
            "cd /var/oases/skills/tavily-search && python3 scripts/search.py 'query'",
        ] {
            let scoped = names(for: command)
            XCTAssertTrue(scoped.contains("TAVILY_API_KEY"), command)
            XCTAssertFalse(scoped.contains("OPENAI_API_KEY"), command)
            XCTAssertFalse(scoped.contains("GITHUB_TOKEN"), command)
        }
        XCTAssertFalse(names(for: "ls /var/minis/skills/").contains("TAVILY_API_KEY"))
        XCTAssertFalse(names(for: "cat /var/minis/skills/missing-skill/SKILL.md").contains("TAVILY_API_KEY"))
    }

    func testSkillScanPicksUpEditedScripts() throws {
        let command = "python3 /var/minis/skills/tavily-search/scripts/search.py"
        XCTAssertFalse(names(for: command).contains("GITHUB_TOKEN"))
        let script = skillsRoot.appendingPathComponent("tavily-search/scripts/search.py")
        try "import os\nkey = os.environ.get(\"TAVILY_API_KEY\")\ntoken = os.environ[\"GITHUB_TOKEN\"]\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: script.path)
        XCTAssertTrue(names(for: command).contains("GITHUB_TOKEN"))
    }

    func testSkillIdsCannotTraverse() {
        XCTAssertEqual(ShellEnvironmentScope.referencedSkillIds(in: "cat /var/minis/skills/../x /var/oases/skills/./y"), [])
        XCTAssertEqual(ShellEnvironmentScope.referencedSkillIds(in: "/var/minis/skills/a-b_c.d/run.sh"), ["a-b_c.d"])
    }

    func testRedactionMasksLongInjectedValuesLongestFirst() {
        let env = [
            "A": "abcdefgh12",
            "B": "abcdefgh12345",
            "SHORT": "1234567",
            "TZ": "Asia/Shanghai",
        ]
        let redactable = ShellEnvironmentScope.redactableSecrets(in: env)
        XCTAssertEqual(redactable, ["abcdefgh12345", "abcdefgh12"])
        let masked = ShellEnvironmentScope.redact(
            "b=abcdefgh12345 a=abcdefgh12 s=1234567 tz=Asia/Shanghai", secrets: redactable)
        XCTAssertEqual(masked, "b=*** a=*** s=1234567 tz=Asia/Shanghai")
    }
}
