import Foundation

/// Loads SKILL.md manifests from the app's sandboxed
/// `Documents/Skills/` directory and registers each as an agent
/// tool. Users drop skill packs into iCloud / Files / AirDrop the
/// folder; on next launch the agent automatically picks them up.
///
/// Each skill becomes a `ManifestBackedTool`. Execution goes:
///   - If a `command` is defined → call `shell_local` with the
///     command, substituting `$key` placeholders from inputs.
///     (When iSH is not yet integrated, `shell_local` returns the
///     "not integrated" message — surfaces gracefully through the
///     agent error path.)
///   - If no command → return the manifest body as a "static skill"
///     response (useful for prompt-only skills that just inject
///     knowledge).
enum SkillImporter {
    static let skillsDirectoryName = "Skills"

    /// Scan + register everything under Documents/Skills/. Safe to
    /// call multiple times — re-registers silently update existing
    /// entries.
    @discardableResult
    static func loadAndRegister() -> Int {
        let fm = FileManager.default
        guard let docs = try? fm.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return 0 }
        let dir = docs.appendingPathComponent(skillsDirectoryName, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var loaded = 0
        for entry in entries {
            // Skills can be either a single SKILL.md or a folder
            // containing SKILL.md (with associated scripts).
            let candidate: URL
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                candidate = entry.appendingPathComponent("SKILL.md")
            } else if entry.lastPathComponent.uppercased() == "SKILL.MD" {
                candidate = entry
            } else {
                continue
            }
            guard let raw = try? String(contentsOf: candidate, encoding: .utf8),
                  let manifest = SkillManifest.parse(raw) else { continue }
            // A dropped-in SKILL.md must not replace a built-in tool (one
            // named `shell_execute` or `file_read`, say, would take over that
            // name without its permission gate). Re-registering manifest
            // tools on a rescan is fine.
            if let existing = ToolRegistry.shared.tool(named: manifest.name),
               !(existing is ManifestBackedTool) {
                continue
            }
            ToolRegistry.shared.register(ManifestBackedTool(manifest: manifest))
            loaded += 1
        }
        return loaded
    }
}

/// Tool wrapper for a `SkillManifest`. Invocation delegates to the
/// manifest's `command` via `shell_local` (when iSH is available),
/// or returns the manifest body as a prompt-only response.
final class ManifestBackedTool: AgentTool, @unchecked Sendable {
    let descriptor: ToolDescriptor
    private let manifest: SkillManifest

    init(manifest: SkillManifest) {
        self.manifest = manifest
        self.descriptor = manifest.toDescriptor()
    }

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        // Prompt-only skill — no command. Return the markdown body
        // so the model can read it as context.
        guard let cmd = manifest.command, !cmd.isEmpty else {
            return .textOnly(manifest.bodyMarkdown)
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let resolved = Self.resolvedCommand(template: cmd, arguments: args)
        // Delegate to shell_local. When iSH is offline this returns
        // a structured message; when online it executes the command.
        guard let shell = ToolRegistry.shared.tool(named: "shell_local") else {
            // i18n-ignore: tool result the model reads
            return .textOnly("⚠️ 该技能需要 shell_local，但 ShellTool 未注册。")
        }
        let shellArgsJSON = "{\"command\":\(Self.jsonString(resolved))}"
        return try await shell.invoke(argumentsJSON: shellArgsJSON, onProgress: onProgress)
    }

    /// Shell names an argument may never set: they steer the shell or the
    /// dynamic loader rather than carry data.
    private static let reservedNames: Set<String> = [
        "PATH", "IFS", "HOME", "ENV", "BASH_ENV", "CDPATH", "SHELL",
        "PS1", "PS2", "PS4", "PWD", "OLDPWD", "OPTIND",
    ]

    /// The manifest command with the model's arguments bound as shell
    /// variables in front of it. Arguments used to be spliced into the
    /// command text, so a value like `x; rm -rf ~` ran as shell syntax;
    /// now `$key` / `${key}` expand to plain data. Only arguments the
    /// template references are bound.
    static func resolvedCommand(template: String, arguments: [String: Any]) -> String {
        var assignments: [String] = []
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
            guard isBindableName(key), references(template, key) else { continue }
            let stringValue: String
            if let s = value as? String { stringValue = s }
            else if let n = value as? NSNumber { stringValue = n.stringValue }
            else { stringValue = "\(value)" }
            assignments.append("\(key)=\(shellQuote(stringValue))")
        }
        guard !assignments.isEmpty else { return template }
        return assignments.joined(separator: "\n") + "\n" + template
    }

    private static func isBindableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
        else { return false }
        return !reservedNames.contains(name) && !name.hasPrefix("LD_") && !name.hasPrefix("DYLD_")
    }

    /// Whether `template` expands `$name` or `${name}`.
    private static func references(_ template: String, _ name: String) -> Bool {
        if template.contains("${\(name)}") { return true }
        var searchStart = template.startIndex
        while let found = template.range(of: "$\(name)", range: searchStart..<template.endIndex) {
            guard found.upperBound < template.endIndex else { return true }
            let next = template[found.upperBound]
            if !(next == "_" || next.isLetter || next.isNumber) { return true }
            searchStart = found.upperBound
        }
        return false
    }

    private static func shellQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip surrounding brackets to get back the JSON-quoted string.
        return String(str.dropFirst().dropLast())
    }
}
