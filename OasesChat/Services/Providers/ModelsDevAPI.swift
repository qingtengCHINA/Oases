import Foundation

private let logger = AppLogger(category: "ModelsDevAPI")

/// Fetches and caches the models.dev provider registry.
/// Used as a fallback when a provider's /v1/models endpoint is unavailable,
/// and as the source of truth for model capabilities (modality, context window, output limit).
enum ModelsDevAPI {

    private static let sourceURL = "https://models.dev/api.json"
    private static let cacheTTL: TimeInterval = 48 * 3600 // 48 hours

    // MARK: - Provider-key mapping for enrichment lookups

    /// Maps the `provider` string stored in LLMModel to one or more models.dev provider keys.
    /// Order matters — first match wins.
    private static let providerKeyMap: [String: [String]] = [
        "Anthropic": ["anthropic"],
        "Google": ["google", "google-vertex"],
        "OpenAI": ["openai"],
        "OpenRouter": ["openrouter"],
        "Antigravity": [],  // Custom proxy, no public models.dev entry
    ]

    // MARK: - Public: Fetch models by base URL

    /// Look up models for a provider by matching its API base URL against models.dev entries.
    /// Tries both with and without `/v1` suffix, normalizing trailing slashes.
    /// Returns immediately from bundled/cached data; network refresh happens in the background.
    static func fetchModels(forBaseURL baseURL: String) -> [LLMModel] {
        guard let registry = loadRegistry() else {
            logger.info("models.dev registry not loaded")
            return []
        }

        logger.info("models.dev lookup: baseURL=\(baseURL), registry has \(registry.count) providers")

        // Phase 1: Exact API base match (with/without /v1)
        let candidates = normalizedCandidates(for: baseURL)
        logger.info("models.dev phase1: candidates=\(candidates)")
        for (_, provider) in registry {
            guard let api = provider.api, !api.isEmpty else { continue }
            let normalizedAPI = stripTrailingSlash(api)
            for candidate in candidates {
                if candidate == normalizedAPI {
                    let models = buildModels(from: provider)
                    logger.info("Exact match \(provider.id) (api=\(api)) — \(models.count) models")
                    return models
                }
            }
        }

        // Phase 2: Hostname fallback — match by full hostname when exact path doesn't match
        let inputHost = extractHost(from: baseURL)
        logger.info("models.dev phase2: inputHost=\(inputHost ?? "nil")")
        if let inputHost {
            for (_, provider) in registry {
                guard let api = provider.api, !api.isEmpty,
                      let providerHost = extractHost(from: api) else { continue }
                if inputHost == providerHost {
                    let models = buildModels(from: provider)
                    logger.info("Host match \(provider.id) (host=\(providerHost), api=\(api)) — \(models.count) models")
                    return models
                }
            }
        }

        logger.info("No models.dev match for base URL: \(baseURL)")
        return []
    }

    private static func buildModels(from provider: ModelsDevProvider) -> [LLMModel] {
        provider.models.compactMap { (_, model) -> LLMModel? in
            let family = model.family?.lowercased() ?? ""
            if family.contains("embedding") || family.contains("moderation") { return nil }
            return LLMModel(
                id: model.id,
                displayName: BrandNeutralCopy.modelName(model.name ?? model.id),
                provider: provider.name ?? provider.id,
                modalityOverride: model.resolvedModality,
                contextWindow: model.limit?.context,
                maxOutputTokens: model.limit?.output,
                supportsReasoning: model.reasoning,
                interleavedReasoningField: model.interleaved?.field
            )
        }
    }

    /// Extract the full hostname from a URL string.
    /// e.g. "https://coding.dashscope.aliyuncs.com/v1" → "coding.dashscope.aliyuncs.com"
    private static func extractHost(from urlString: String) -> String? {
        URL(string: stripTrailingSlash(urlString))?.host?.lowercased()
    }

    // MARK: - Public: Enrich a single model with models.dev data

    /// Enrich an LLMModel with capabilities from models.dev (modality, context window, output limit).
    /// Looks up by provider name + model ID. Returns the original model if no match found.
    /// Only fills in fields that are currently nil/unset on the model.
    static func enrichModel(_ model: LLMModel) -> LLMModel {
        guard let registry = loadRegistry() else { return model }

        let keys = providerKeyMap[model.provider] ?? []
        for key in keys {
            guard let prov = registry[key], let devModel = prov.models[model.id] else { continue }
            return applyDevData(to: model, from: devModel)
        }

        // Fallback: scan all providers for the model ID (handles proxies, custom providers)
        for (_, prov) in registry {
            if let devModel = prov.models[model.id] {
                return applyDevData(to: model, from: devModel)
            }
        }

        return model
    }

    /// Enrich an array of models in bulk.
    static func enrichModels(_ models: [LLMModel]) -> [LLMModel] {
        guard let registry = loadRegistry() else { return models }
        return models.map { model in
            // Try mapped provider keys first
            let keys = providerKeyMap[model.provider] ?? []
            for key in keys {
                if let prov = registry[key], let devModel = prov.models[model.id] {
                    return applyDevData(to: model, from: devModel)
                }
            }
            // Fallback scan
            for (_, prov) in registry {
                if let devModel = prov.models[model.id] {
                    return applyDevData(to: model, from: devModel)
                }
            }
            return model
        }
    }

    // MARK: - Apply models.dev data to LLMModel

    private static func applyDevData(to model: LLMModel, from devModel: ModelsDevModel) -> LLMModel {
        var result = model

        // Modality: models.dev is the source of truth — always apply when available.
        // This overrides both provider-level defaults and API-parsed modalities,
        // since models.dev has accurate per-model data (e.g. pdf support distinctions).
        if let devModality = devModel.resolvedModality {
            result.modalityOverride = devModality
        }

        // Context window: models.dev is the source of truth
        if let ctx = devModel.limit?.context {
            result.contextWindow = ctx
        }

        // Max output tokens: models.dev is the source of truth
        if let out = devModel.limit?.output {
            result.maxOutputTokens = out
        }

        // Reasoning capability
        if let reasoning = devModel.reasoning {
            result.supportsReasoning = reasoning
        }

        // Interleaved reasoning field (e.g. "reasoning_content" for DeepSeek/Kimi)
        if let field = devModel.interleaved?.field {
            result.interleavedReasoningField = field
        }

        return result
    }

    // MARK: - URL Matching Helpers

    private static func normalizedCandidates(for url: String) -> [String] {
        let stripped = stripTrailingSlash(url)
        var results = [stripped]
        if stripped.hasSuffix("/v1") {
            results.append(String(stripped.dropLast(3)))
        } else {
            results.append(stripped + "/v1")
        }
        return results
    }

    private static func stripTrailingSlash(_ s: String) -> String {
        var r = s
        while r.hasSuffix("/") { r = String(r.dropLast()) }
        return r
    }

    // MARK: - Registry Cache

    /// Guards `cachedRegistry` / `cacheTimestamp` / `isRefreshing`: the registry
    /// is read from model refreshes on arbitrary threads while the background
    /// fetch writes it. (A dictionary read racing a write can crash.)
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedRegistry: [String: ModelsDevProvider]?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    /// True while a background network fetch is in flight (prevents concurrent fetches).
    private nonisolated(unsafe) static var isRefreshing = false
    private nonisolated(unsafe) static var loggedMissingBundle = false

    // Test seams: where the downloaded copy lives, which bundle may hold the
    // fallback, and whether a network refresh may start. Production never
    // changes them.
    nonisolated(unsafe) static var diskCacheURLOverride: URL?
    nonisolated(unsafe) static var fallbackBundle: Bundle = .main
    nonisolated(unsafe) static var allowsNetworkRefresh = true

    static func resetInMemoryCache() {
        cacheLock.lock()
        cachedRegistry = nil
        cacheTimestamp = nil
        cacheLock.unlock()
    }

    private static func cacheSnapshot() -> (registry: [String: ModelsDevProvider]?, timestamp: Date?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (cachedRegistry, cacheTimestamp)
    }

    private static func storeCache(_ registry: [String: ModelsDevProvider], timestamp: Date) {
        cacheLock.lock()
        cachedRegistry = registry
        cacheTimestamp = timestamp
        cacheLock.unlock()
    }

    /// Returns the registry immediately from memory/disk/bundle (never blocks on network).
    /// Triggers a background refresh when the cache is stale (>24h), at most one at a time.
    private static func loadRegistry() -> [String: ModelsDevProvider]? {
        let snapshot = cacheSnapshot()
        // 1. In-memory cache (fresh)
        if let cached = snapshot.registry, let ts = snapshot.timestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        // 2. In-memory cache exists but stale — return it, schedule refresh
        if let cached = snapshot.registry {
            scheduleBackgroundRefresh()
            return cached
        }

        // 3. Disk cache (downloaded data) — fallback to bundled on parse failure
        if let (diskData, diskDate) = loadDiskCache() {
            if let parsed = parseRegistry(diskData) {
                storeCache(parsed, timestamp: diskDate)
                if Date().timeIntervalSince(diskDate) >= cacheTTL {
                    scheduleBackgroundRefresh()
                }
                return parsed
            } else {
                logger.error("Downloaded models.dev cache failed to parse, falling back to bundled")
            }
        }

        // 4. Bundled fallback, when the app ships one
        if let bundled = loadBundledRegistry() {
            // Treat as fresh to avoid repeated bundled loads within same session
            storeCache(bundled, timestamp: Date())
            scheduleBackgroundRefresh()
            return bundled
        }

        // 5. Nothing yet (first launch, offline): models stay unenriched until
        // the network copy arrives.
        scheduleBackgroundRefresh()
        return nil
    }

    /// Schedule a background refresh if one isn't already in flight.
    private static func scheduleBackgroundRefresh() {
        guard allowsNetworkRefresh else { return }
        cacheLock.lock()
        let alreadyRefreshing = isRefreshing
        isRefreshing = true
        cacheLock.unlock()
        guard !alreadyRefreshing else { return }
        Task.detached(priority: .utility) {
            await refreshFromNetwork()
        }
    }

    private static func refreshFromNetwork() async {
        defer {
            cacheLock.lock()
            isRefreshing = false
            cacheLock.unlock()
        }
        do {
            guard let url = URL(string: sourceURL) else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.error("models.dev HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if let parsed = parseRegistry(data) {
                storeCache(parsed, timestamp: Date())
                saveDiskCache(data)
                logger.info("Background-refreshed models.dev registry: \(parsed.count) providers")
            }
        } catch {
            logger.error("Failed to fetch models.dev: \(error.localizedDescription)")
        }
    }

    private static func parseRegistry(_ data: Data) -> [String: ModelsDevProvider]? {
        do {
            return try JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
        } catch {
            logger.error("Failed to parse models.dev JSON (\(data.count) bytes): \(error)")
            return nil
        }
    }

    // MARK: - Bundled Fallback

    /// The app doesn't ship `models-dev-api.json` (a stale third-party
    /// snapshot); this only loads one if a build adds it. Its absence is
    /// normal, not a failure: it used to `assertionFailure`, which crashed
    /// DEBUG builds on the first model-list fetch after install.
    private static func loadBundledRegistry() -> [String: ModelsDevProvider]? {
        guard let url = fallbackBundle.url(forResource: "models-dev-api", withExtension: "json") else {
            cacheLock.lock()
            let firstMiss = !loggedMissingBundle
            loggedMissingBundle = true
            cacheLock.unlock()
            if firstMiss {
                logger.info("No bundled models.dev registry; enrichment waits for the downloaded copy")
            }
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Bundled models-dev-api.json failed to read: \(url.path)")
            return nil
        }
        guard let parsed = parseRegistry(data) else {
            logger.error("Bundled models-dev-api.json failed to parse (\(data.count) bytes)")
            return nil
        }
        logger.info("Loaded bundled models.dev registry: \(parsed.count) providers")
        return parsed
    }

    // MARK: - Disk Cache

    private static var cacheFileURL: URL {
        if let diskCacheURLOverride { return diskCacheURLOverride }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("dev.oases.chat.ios.models-dev-cache").appendingPathComponent("api.json")
    }

    private static func loadDiskCache() -> (Data, Date)? {
        let url = cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return (data, modified)
    }

    private static func saveDiskCache(_ data: Data) {
        let url = cacheFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - models.dev JSON Models

private struct ModelsDevProvider: Decodable {
    let id: String
    let name: String?
    let api: String?
    let models: [String: ModelsDevModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        api = try container.decodeIfPresent(String.self, forKey: .api)
        models = try container.decodeIfPresent([String: ModelsDevModel].self, forKey: .models) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case id, name, api, models
    }
}

private struct ModelsDevModel: Decodable {
    let id: String
    let name: String?
    let family: String?
    let modalities: ModelsDevModalities?
    let limit: ModelsDevLimit?
    let reasoning: Bool?
    let interleaved: ModelsDevInterleaved?

    /// Convert models.dev modalities to app ModelModality.
    var resolvedModality: ModelModality? {
        guard let mod = modalities else { return nil }
        var result: ModelModality = []
        let inp = mod.input ?? []
        let out = mod.output ?? []
        if inp.contains("text")  { result.insert(.textInput) }
        if inp.contains("image") { result.insert(.imageInput) }
        if inp.contains("pdf")   { result.insert(.pdfInput) }
        if inp.contains("audio") { result.insert(.audioInput) }
        if inp.contains("video") { result.insert(.videoInput) }
        if out.contains("text")  { result.insert(.textOutput) }
        if out.contains("image") { result.insert(.imageOutput) }
        if out.contains("audio") { result.insert(.audioOutput) }
        if out.contains("video") { result.insert(.videoOutput) }
        return result.isEmpty ? nil : result
    }
}

private struct ModelsDevModalities: Decodable {
    let input: [String]?
    let output: [String]?
}

private struct ModelsDevLimit: Decodable {
    let context: Int?
    let output: Int?
}

/// `interleaved` can be either a bool (`true`) or an object (`{"field": "reasoning_content"}`).
private struct ModelsDevInterleaved: Decodable {
    let field: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try object first
        if let dict = try? container.decode([String: String].self) {
            field = dict["field"]
        } else if let flag = try? container.decode(Bool.self) {
            // bool true → default field name "reasoning_content"
            field = flag ? "reasoning_content" : nil
        } else {
            field = nil
        }
    }
}
