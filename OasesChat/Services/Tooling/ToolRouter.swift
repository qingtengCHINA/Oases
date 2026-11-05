import Foundation

struct ToolRoute {
    let candidates: [ToolCapabilityCandidate]
    let allowlist: Set<String>
    let selectedToolNames: Set<String>
    let protectedToolNames: Set<String>
    let schemaJSON: String?
    let schemaByteCount: Int
    let budget: Int
    let didFitBudget: Bool
}

/// Two-stage project-tool router:
/// 1. match a compact capability shortlist;
/// 2. materialize only the matching registry descriptors, subject to budget.
struct ToolRouter {
    private let surface: AgentSurface
    private let registry: ToolRegistry

    init(surface: AgentSurface = .project, registry: ToolRegistry = .shared) {
        self.surface = surface
        self.registry = registry
    }

    func route(
        prompt: String,
        schemaBudgetBytes: Int = 36_000,
        candidateLimit: Int = 4,
        preferredToolNames: Set<String>? = nil
    ) -> ToolRoute {
        let descriptors = registry.descriptors(for: surface)
        let catalog = ToolCatalog(descriptors: descriptors)
        let candidates = catalog.candidates(
            for: prompt,
            surface: surface,
            limit: candidateLimit
        )
        let matchedNames = Set(candidates.flatMap(\.toolNames))
        let allowlist: Set<String>
        if let preferredToolNames, !preferredToolNames.isEmpty {
            // The planner remains the source of intent. The catalog still
            // records the compact capability shortlist, while this second
            // stage validates the planner's names against the live registry.
            let registeredNames = Set(descriptors.map(\.name))
            allowlist = preferredToolNames.intersection(registeredNames)
        } else {
            allowlist = matchedNames
        }
        let protected = catalog.coreToolNames(for: allowlist)

        guard !allowlist.isEmpty else {
            return ToolRoute(
                candidates: [],
                allowlist: [],
                selectedToolNames: [],
                protectedToolNames: [],
                schemaJSON: nil,
                schemaByteCount: 0,
                budget: max(0, schemaBudgetBytes),
                didFitBudget: true
            )
        }

        let fit = fitSchema(
            allowlist: allowlist,
            protected: protected,
            budget: schemaBudgetBytes
        )
        return ToolRoute(
            candidates: candidates,
            allowlist: allowlist,
            selectedToolNames: fit.names,
            protectedToolNames: protected,
            schemaJSON: fit.json,
            schemaByteCount: fit.json?.utf8.count ?? 0,
            budget: max(0, schemaBudgetBytes),
            didFitBudget: fit.didFit
        )
    }

    private func fitSchema(
        allowlist: Set<String>,
        protected: Set<String>,
        budget: Int
    ) -> (json: String?, names: Set<String>, didFit: Bool) {
        guard budget > 0 else { return (nil, [], false) }

        let descriptors = registry.descriptors(for: surface, allowedNames: allowlist)
        guard !descriptors.isEmpty else { return (nil, [], true) }

        var selected = Set(descriptors.map(\.name))
        let byteCount: (Set<String>) -> Int = { names in
            self.registry.openAIToolsJSON(for: self.surface, allowedNames: names)?.utf8.count ?? 0
        }

        if byteCount(selected) > budget {
            // Lower-priority, non-core entries are removed first. The order is
            // deterministic, so proxy caching and tests remain stable.
            let optional = descriptors
                .filter { !protected.contains($0.name) }
                .sorted { lhs, rhs in
                    if lhs.requiresPermission != rhs.requiresPermission {
                        return lhs.requiresPermission && !rhs.requiresPermission
                    }
                    return lhs.name > rhs.name
                }
            for descriptor in optional where byteCount(selected) > budget {
                selected.remove(descriptor.name)
            }
        }

        let count = byteCount(selected)
        guard count <= budget, !selected.isEmpty else {
            // A single protected schema larger than the budget cannot be sent
            // without violating the hard byte limit. Report no schema rather
            // than silently sending an oversized request.
            return (nil, [], false)
        }
        return (
            registry.openAIToolsJSON(for: surface, allowedNames: selected),
            selected,
            true
        )
    }
}
