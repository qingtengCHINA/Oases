import Foundation

/// Parsed representation of a SKILL.md manifest. Compatible with the
/// format used by Anthropic Skills, Ogent SKILL.md, and Claude
/// Code skill packs:
///
/// ```
/// ---
/// name: my-skill
/// description: A short summary of what the skill does
/// inputs:
///   - query: { type: string, required: true }
///   - limit: { type: integer, default: 10 }
/// surfaces: [chat, project]
/// requires_permission: false
/// command: ./run.sh "$query"
/// ---
///
/// # My Skill
///
/// Markdown body describing the skill in detail. The agent reads
/// `description` for the tool manifest; this body is for humans.
/// ```
///
/// We don't execute the `command` natively yet — that requires the
/// iSH shell (S6). For now the parser converts the manifest into a
/// `ToolDescriptor` so the skill at least appears in the tool list,
/// and routes execution through `SkillImporter`'s wrapper tool which
/// can later be backed by iSH.
struct SkillManifest: Equatable {
    let name: String
    let description: String
    let displayName: String?
    let surfaces: [AgentSurface]
    let requiresPermission: Bool
    /// Raw JSON-Schema input definition. Parsed from the YAML-ish
    /// `inputs:` block; defaults to an empty object schema.
    let inputSchemaJSON: String
    /// Shell command template — placeholders like `$query`,
    /// `${path}` are substituted from the input arguments before
    /// execution. Empty when the skill doesn't shell out.
    let command: String?
    /// Markdown body after the front-matter — preserved for the UI
    /// to render as the skill's "About" sheet.
    let bodyMarkdown: String

    /// Parse a SKILL.md file. Returns nil if the front-matter is
    /// missing required fields.
    static func parse(_ raw: String) -> SkillManifest? {
        guard let firstFence = raw.range(of: "---") else { return nil }
        let afterFirst = firstFence.upperBound
        guard let closingFence = raw.range(of: "\n---", range: afterFirst..<raw.endIndex) else {
            return nil
        }
        let frontBody = String(raw[afterFirst..<closingFence.lowerBound])
        let bodyAfter = String(raw[closingFence.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        let yaml = parseYAMLKeys(frontBody)
        guard let name = yaml["name"], !name.isEmpty,
              let description = yaml["description"], !description.isEmpty else {
            return nil
        }

        let surfacesRaw = yaml["surfaces"] ?? "[chat]"
        let surfaces = surfacesRaw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { token -> AgentSurface? in
                let s = token.trimmingCharacters(in: .whitespaces).lowercased()
                return AgentSurface(rawValue: s)
            }

        return SkillManifest(
            name: name,
            description: description,
            displayName: yaml["display_name"],
            surfaces: surfaces.isEmpty ? [.chat] : surfaces,
            requiresPermission: (yaml["requires_permission"] ?? "false").lowercased() == "true",
            inputSchemaJSON: yaml["input_schema"] ?? "{\"type\":\"object\",\"properties\":{}}",
            command: yaml["command"],
            bodyMarkdown: bodyAfter
        )
    }

    /// Tiny key:value parser — only supports flat YAML, which is all
    /// we promise SKILL.md authors. Lines starting with `#` are
    /// comments. Values can be quoted (handled trivially).
    private static func parseYAMLKeys(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let ws = CharacterSet.whitespaces
        for line in s.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = String(line).trimmingCharacters(in: ws)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: ws)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: ws)
            // Strip surrounding quotes.
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    func toDescriptor() -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            summary: description,
            displayName: displayName ?? name,
            inputSchemaJSON: inputSchemaJSON,
            surfaces: surfaces,
            requiresPermission: requiresPermission
        )
    }
}
