import Foundation
import Security

enum APIError: LocalizedError {
    case missingBaseURL
    case invalidURL
    case dataSharingConsentRequired
    case badStatus(Int, String?)
    case decode(Error)
    case transport(Error)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: return String(localized: "未配置 API Base URL", comment: "Error: the API base URL is not configured")
        case .invalidURL: return String(localized: "URL 无效", comment: "Error: a request URL is invalid")
        case .dataSharingConsentRequired:
            return String(localized: "发送内容给 AI 服务商前，需要先同意 AI 数据共享说明", comment: "Error: user must accept the AI data-sharing notice before sending content to an AI provider")
        case .badStatus(let code, let body):
            let suffix = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let suffix, !suffix.isEmpty {
                return String(localized: "服务返回 \(code)：\(String(suffix.prefix(240)))", comment: "Error: server returned HTTP status %lld with response body excerpt %@")
            }
            return String(localized: "服务返回 \(code)", comment: "Error: server returned HTTP status code")
        case .decode(let err): return String(localized: "解析失败：\(err.localizedDescription)", comment: "Error: response parsing failed; argument is the underlying error")
        case .transport(let err): return err.localizedDescription
        case .server(let message): return message
        }
    }
}

struct APIClient {
    static let oasesOpenCodeSession: String = {
        let key = "oases.opencode.session"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()

    let baseURL: URL
    let apiKey: String?
    let session: URLSession

    init(baseURL: URL? = nil, apiKey: String? = nil, session: URLSession = .shared) {
        // Default to the generated Secrets (from .env → api.oases.dev/v1),
        // allowing an explicit override for tests/previews.
        let resolved = baseURL ?? Secrets.apiBaseURL
        self.baseURL = resolved
        self.apiKey = apiKey ?? Secrets.apiKey
        self.session = session
    }

    init(route: AIProviderRouting.Route, session: URLSession = .shared) {
        self.baseURL = route.baseURL
        self.apiKey = route.apiKey
        self.session = session
    }

    /// A URLSession with a generous request timeout for slow endpoints
    /// (image generation — especially higher-quality models — can take
    /// well over the default 60s).
    static let longTimeout: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// A URLSession tuned for streaming chat completions. The default 60s
    /// `timeoutIntervalForRequest` kills the stream when the model pauses for
    /// more than a minute between token chunks (long generations, long
    /// reasoning). Here the per-request timeout is effectively disabled (5h)
    /// while `timeoutIntervalForResource` still bounds the whole call, so a
    /// genuinely hung connection eventually fails instead of hanging forever.
    static let streaming: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5 * 3600
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func makeRequest(path: String, method: String = "POST", body: Data? = nil, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        // Model-list reads remain available before consent. Only endpoints
        // carrying user content are blocked. The exemption is decided by the
        // host, not the route kind: a "local model" route is only local when
        // its base URL is loopback (the setting accepts any http(s) URL).
        if Self.requiresDataSharingConsent(path: path, method: method),
           !AIDataSharingConsent.allowsRequest(to: baseURL) {
            throw APIError.dataSharingConsentRequired
        }
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let preferred = Locale.preferredLanguages.first {
            req.setValue(preferred, forHTTPHeaderField: "Accept-Language")
        }
        // Direct upstream auth — the key is injected from .env at build time
        // and kept out of git (see OasesChat/Generated/Secrets.swift).
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if baseURL.host?.contains("oases.dev") == true {
            req.setValue(Self.oasesOpenCodeSession, forHTTPHeaderField: "x-opencode-session")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = body }
        return req
    }

    private static func requiresDataSharingConsent(path: String, method: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        let normalized = path
            .split(separator: "?")
            .first
            .map(String.init) ?? ""
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return normalized == "chat/completions"
            || normalized == "images/generations"
            || normalized.hasPrefix("search/")
    }

    func data(path: String, method: String = "POST", body: Data?) async throws -> (Data, HTTPURLResponse) {
        var req = try makeRequest(path: path, method: method, body: body)
        await applyAttestationHeaders(&req)
        do {
            let (data, response) = try await AIRequestGate.data(session, for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
            guard (200..<300).contains(http.statusCode) else {
                if Self.canSelfHealAttestation(http: http, data: data, targetsGateway: targetsOasesGateway) {
                    AttestationClient.shared.resetEnrollment()
                    var retry = try makeRequest(path: path, method: method, body: body)
                    await applyAttestationHeaders(&retry)
                    let (retryData, retryResponse) = try await AIRequestGate.data(session, for: retry)
                    guard let retryHTTP = retryResponse as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
                    guard (200..<300).contains(retryHTTP.statusCode) else {
                        throw APIError.badStatus(retryHTTP.statusCode, Self.responseSnippet(retryData))
                    }
                    return (retryData, retryHTTP)
                }
                throw APIError.badStatus(http.statusCode, Self.responseSnippet(data))
            }
            return (data, http)
        } catch let err as APIError { throw err }
        // Refused by `AIRequestGate` (a consent missing or taken back): the run ends quietly.
        catch let refusal as CancellationError { throw refusal }
        catch { throw APIError.transport(error) }
    }

    func bytes(path: String, body: Data?) async throws -> URLSession.AsyncBytes {
        var req = try makeRequest(path: path, body: body, extraHeaders: ["Accept": "text/event-stream"])
        await applyAttestationHeaders(&req)
        do {
            let (bytes, response) = try await AIRequestGate.bytes(session, for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
            guard (200..<300).contains(http.statusCode) else {
                let snippet = try await Self.responseSnippet(bytes)
                if Self.canSelfHealAttestation(http: http, data: snippet?.data(using: .utf8), targetsGateway: targetsOasesGateway) {
                    AttestationClient.shared.resetEnrollment()
                    var retry = try makeRequest(path: path, body: body, extraHeaders: ["Accept": "text/event-stream"])
                    await applyAttestationHeaders(&retry)
                    let (retryBytes, retryResponse) = try await AIRequestGate.bytes(session, for: retry)
                    guard let retryHTTP = retryResponse as? HTTPURLResponse else { throw APIError.transport(URLError(.badServerResponse)) }
                    guard (200..<300).contains(retryHTTP.statusCode) else {
                        throw APIError.badStatus(retryHTTP.statusCode, try await Self.responseSnippet(retryBytes))
                    }
                    return retryBytes
                }
                throw APIError.badStatus(http.statusCode, snippet)
            }
            return bytes
        } catch let err as APIError { throw err }
        // Refused by `AIRequestGate` (a consent missing or taken back): the run ends quietly.
        catch let refusal as CancellationError { throw refusal }
        catch { throw APIError.transport(error) }
    }

    // MARK: - App Attest (oases.dev gateway only)

    private var targetsOasesGateway: Bool {
        baseURL.host?.contains("oases.dev") == true
    }

    /// Appends the App Attest assertion headers to an Oases-gateway request.
    /// Graceful degradation (接入指南 §7): any signing failure — unsupported
    /// device, not configured, transient DC error — downgrades to sending the
    /// request unsigned and lets the gateway's policy decide (observe 放行并
    /// 记录、enforce 拒绝)。绝不能因签名失败而阻断请求。
    private func applyAttestationHeaders(_ request: inout URLRequest) async {
        guard targetsOasesGateway,
              let url = request.url,
              let method = request.httpMethod else { return }
        do {
            let headers = try await AttestationClient.shared.signedHeaders(
                method: method,
                path: url.path,
                body: request.httpBody
            )
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } catch {
            Self.attestLog.warning("unsigned send (\(url.path)): \(error.localizedDescription)")
        }
    }

    private static let attestLog = AppLogger(category: "Attest")

    /// 401 self-heal gate: the gateway answers `device_not_enrolled` when its
    /// enrolled-key record for this device is missing; only then do we reset
    /// the enrollment and retry once (re-enrollment happens lazily inside the
    /// next signedHeaders call).
    private static func canSelfHealAttestation(http: HTTPURLResponse, data: Data?, targetsGateway: Bool) -> Bool {
        guard targetsGateway, http.statusCode == 401, let data, !data.isEmpty else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              error["code"] as? String == "device_not_enrolled" else { return false }
        return true
    }

    private static func responseSnippet(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let limited = data.prefix(4096)
        return String(data: limited, encoding: .utf8) ?? String(decoding: limited, as: UTF8.self)
    }

    private static func responseSnippet(_ bytes: URLSession.AsyncBytes) async throws -> String? {
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4096 { break }
        }
        return responseSnippet(buffer)
    }
}

enum AIProviderRouting {
    enum RouteKind: String {
        case localISHModel = "local_ish_model"
        case globalDirectProvider = "global_direct_provider"
        case projectDirectProvider = "project_direct_provider"
        case inAppProjectProvider = "in_app_project_provider"
        case oasesDefault = "oases_default"
    }

    struct Route {
        let baseURL: URL
        let apiKey: String?
        let kind: RouteKind
        let modelOverride: String?

        init(baseURL: URL, apiKey: String?, kind: RouteKind, modelOverride: String? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.kind = kind
            self.modelOverride = modelOverride
        }

        var usesDirectProvider: Bool {
            true
        }

        var hostDescription: String {
            baseURL.host(percentEncoded: false) ?? baseURL.host ?? "unknown-host"
        }
    }

    static var nonLocalProjectRoute: Route? {
        if let runtimeRoute = AIProviderSettingsStore.projectRoute {
            return runtimeRoute
        }
        if let url = Secrets.projectAIBaseURL {
            return Route(
                baseURL: url,
                apiKey: Secrets.projectAIAPIKey ?? Secrets.directAIAPIKey ?? Secrets.apiKey,
                kind: .projectDirectProvider
            )
        }
        if let url = Secrets.directAIBaseURL {
            return Route(
                baseURL: url,
                apiKey: Secrets.directAIAPIKey ?? Secrets.apiKey,
                kind: .globalDirectProvider
            )
        }
        return nil
    }

    static var configuredProjectRoute: Route? {
        if let localRoute = OgentLocalModelSettingsStore.projectRoute {
            return localRoute
        }
        return nonLocalProjectRoute
    }

    static var projectRoute: Route? {
        configuredProjectRoute
    }

    /// The route the project model request will actually use. `projectRoute`
    /// intentionally remains optional because settings need to distinguish
    /// “no override” from “custom provider configured”. Request construction,
    /// however, should use one explicit route even for the built-in Oases
    /// endpoint so diagnostics and authorization are identical on every path.
    static var effectiveProjectRoute: Route {
        projectRoute ?? Route(
            baseURL: Secrets.apiBaseURL,
            apiKey: Secrets.apiKey,
            kind: .oasesDefault
        )
    }

    static var projectRouteSummary: String {
        guard let route = projectRoute else {
            let host = Secrets.apiBaseURL.host(percentEncoded: false) ?? Secrets.apiBaseURL.host ?? "default-oases"
            return "project_ai_route=oases_default host=\(host) oases_endpoint_active=1 custom_provider_active=0 local_model_active=0"
        }
        let model = route.modelOverride?.isEmpty == false ? " model_override=\(route.modelOverride!)" : ""
        let local = route.kind == .localISHModel ? " local_model_active=1 custom_provider_active=0" : " local_model_active=0 custom_provider_active=1"
        return "project_ai_route=\(route.kind.rawValue) host=\(route.hostDescription)\(model)\(local) oases_endpoint_active=0"
    }

    // i18n-ignore: model-facing routing note appended to the Ogent system prompt
    static var projectPromptNote: String {
        if let route = projectRoute {
            if route.kind == .localISHModel {
                return "工程模式模型请求已配置为本机 iSH local model route（\(route.hostDescription)）；请先用 `ogent_agent model_probe` 确认 iSH 内本地模型服务正在响应。" // i18n-ignore: model-facing prompt note
            }
            return "工程模式模型请求已配置为从设备直连用户指定 provider（\(route.hostDescription)）；工程工具执行仍在本机 iSH/Ogent 中完成。" // i18n-ignore: model-facing prompt note
        }
        return "工程模式模型请求使用 Oases 默认端点；工程工具执行、Linux/iSH workspace、产物导出、MCP、技能、子代理和 wiki/RAG 仍在本机 iSH/Ogent 中完成。" // i18n-ignore: model-facing prompt note
    }
}

enum OgentLocalModelSettingsStore {
    struct Snapshot: Equatable {
        let isEnabled: Bool
        let baseURLString: String
        let modelID: String
        let runtimeKind: String
        let modelFile: String
        let extraArgs: String
        let startCommand: String

        var isConfigured: Bool {
            isEnabled
                && URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
    }

    private static let enabledKey = "ogent.local-model.enabled"
    private static let baseURLKey = "ogent.local-model.baseURL"
    private static let modelIDKey = "ogent.local-model.modelID"
    private static let runtimeKindKey = "ogent.local-model.runtimeKind"
    private static let modelFileKey = "ogent.local-model.modelFile"
    private static let extraArgsKey = "ogent.local-model.extraArgs"
    private static let startCommandKey = "ogent.local-model.startCommand"

    static let defaultBaseURLString = "http://127.0.0.1:11434/v1"
    static let defaultRuntimeKind = "llama.cpp"
    static let defaultExtraArgs = "--ctx-size 4096"

    static var projectRoute: AIProviderRouting.Route? {
        let snapshot = snapshot()
        guard snapshot.isEnabled,
              let url = URL(string: snapshot.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let model = snapshot.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIProviderRouting.Route(
            baseURL: url,
            apiKey: nil,
            kind: .localISHModel,
            modelOverride: model.isEmpty ? nil : model
        )
    }

    static func snapshot() -> Snapshot {
        let base = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURLString
        let model = UserDefaults.standard.string(forKey: modelIDKey) ?? ""
        let runtimeKind = UserDefaults.standard.string(forKey: runtimeKindKey) ?? defaultRuntimeKind
        let modelFile = UserDefaults.standard.string(forKey: modelFileKey) ?? ""
        let extraArgs = UserDefaults.standard.string(forKey: extraArgsKey) ?? defaultExtraArgs
        let startCommand = UserDefaults.standard.string(forKey: startCommandKey) ?? ""
        return Snapshot(
            isEnabled: UserDefaults.standard.bool(forKey: enabledKey),
            baseURLString: base,
            modelID: model,
            runtimeKind: runtimeKind,
            modelFile: modelFile,
            extraArgs: extraArgs,
            startCommand: startCommand
        )
    }

    static func save(
        isEnabled: Bool,
        baseURLString: String,
        modelID: String,
        runtimeKind: String = defaultRuntimeKind,
        modelFile: String = "",
        extraArgs: String = defaultExtraArgs,
        startCommand: String = ""
    ) throws {
        let cleanBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty,
              let url = URL(string: cleanBaseURL),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host(percentEncoded: false) != nil || url.host != nil else {
            throw SettingsError.invalidBaseURL
        }
        UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        UserDefaults.standard.set(cleanBaseURL, forKey: baseURLKey)
        UserDefaults.standard.set(modelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelIDKey)
        UserDefaults.standard.set(runtimeKind.trimmingCharacters(in: .whitespacesAndNewlines), forKey: runtimeKindKey)
        UserDefaults.standard.set(modelFile.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelFileKey)
        UserDefaults.standard.set(extraArgs.trimmingCharacters(in: .whitespacesAndNewlines), forKey: extraArgsKey)
        UserDefaults.standard.set(startCommand.trimmingCharacters(in: .whitespacesAndNewlines), forKey: startCommandKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        UserDefaults.standard.removeObject(forKey: modelIDKey)
        UserDefaults.standard.removeObject(forKey: runtimeKindKey)
        UserDefaults.standard.removeObject(forKey: modelFileKey)
        UserDefaults.standard.removeObject(forKey: extraArgsKey)
        UserDefaults.standard.removeObject(forKey: startCommandKey)
    }

    static func runSelfTest() -> String {
        let previous = snapshot()
        defer {
            try? save(
                isEnabled: previous.isEnabled,
                baseURLString: previous.baseURLString,
                modelID: previous.modelID,
                runtimeKind: previous.runtimeKind,
                modelFile: previous.modelFile,
                extraArgs: previous.extraArgs,
                startCommand: previous.startCommand
            )
        }

        do {
            clear()
            let clearOK = projectRoute == nil && snapshot().runtimeKind == defaultRuntimeKind
            try save(
                isEnabled: true,
                baseURLString: "http://127.0.0.1:11434/v1",
                modelID: "llama-local",
                runtimeKind: "llama.cpp",
                modelFile: "/root/.ogent/models/test.gguf",
                extraArgs: "--ctx-size 2048",
                startCommand: "llama-server --model /root/.ogent/models/test.gguf"
            )
            guard let route = projectRoute else {
                return "local_model_settings_failed missing_route"
            }
            let saved = snapshot()
            let ok = clearOK
                && route.kind == .localISHModel
                && route.hostDescription == "127.0.0.1"
                && route.modelOverride == "llama-local"
                && saved.runtimeKind == "llama.cpp"
                && saved.modelFile == "/root/.ogent/models/test.gguf"
                && saved.extraArgs == "--ctx-size 2048"
                && saved.startCommand.hasPrefix("llama-server")
                && AIProviderRouting.projectRouteSummary.contains("local_model_active=1")
            return ok ? "local_model_settings_ok \(AIProviderRouting.projectRouteSummary)" : "local_model_settings_failed \(AIProviderRouting.projectRouteSummary)"
        } catch {
            return "local_model_settings_failed \(error.localizedDescription)"
        }
    }

    enum SettingsError: LocalizedError {
        case invalidBaseURL

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return String(localized: "请输入有效的本机模型 Base URL，例如 http://127.0.0.1:11434/v1。", comment: "Validation error for the local model base URL field")
            }
        }
    }
}

enum AIProviderSettingsStore {
    struct Snapshot: Equatable {
        let baseURLString: String
        let hasAPIKey: Bool

        var isConfigured: Bool {
            !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct ProviderProbeResult: Equatable {
        let configured: Bool
        let ok: Bool
        let summary: String
    }

    private static let baseURLKey = "ogent.project.provider.baseURL"
    private static let keychainService = "dev.oases.chat.ogent.project-provider"
    private static let keychainAccount = "api-key"

    static var projectRoute: AIProviderRouting.Route? {
        let baseURLString = UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !baseURLString.isEmpty, let url = URL(string: baseURLString) else {
            return nil
        }
        return AIProviderRouting.Route(
            baseURL: url,
            apiKey: readAPIKey() ?? Secrets.projectAIAPIKey ?? Secrets.directAIAPIKey ?? Secrets.apiKey,
            kind: .inAppProjectProvider
        )
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            baseURLString: UserDefaults.standard.string(forKey: baseURLKey) ?? "",
            hasAPIKey: readAPIKey()?.isEmpty == false
        )
    }

    static func save(baseURLString: String, apiKey: String?) throws {
        let cleanBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty, let url = URL(string: cleanBaseURL), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              url.host(percentEncoded: false) != nil || url.host != nil else {
            throw SettingsError.invalidBaseURL
        }
        UserDefaults.standard.set(cleanBaseURL, forKey: baseURLKey)
        if let apiKey {
            let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanKey.isEmpty {
                try saveAPIKey(cleanKey)
            }
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        deleteAPIKey()
    }

    static func testProjectProviderConnection() async throws -> String {
        guard let route = AIProviderRouting.projectRoute else {
            throw SettingsError.directProviderNotConfigured
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        let client = APIClient(route: route, session: URLSession(configuration: config))
        let (data, response) = try await client.data(path: "models", method: "GET", body: nil)
        return "provider_test_ok host=\(route.hostDescription) status=\(response.statusCode) \(parseModelsResponse(data))"
    }

    static func probeProjectProvider() async -> ProviderProbeResult {
        guard let route = AIProviderRouting.projectRoute else {
            return ProviderProbeResult(
                configured: false,
                ok: true,
                summary: "provider_probe=skipped reason=using_oases_default \(AIProviderRouting.projectRouteSummary)"
            )
        }

        do {
            let result = try await testProjectProviderConnection()
            let ok = result.contains("provider_test_ok")
            return ProviderProbeResult(
                configured: true,
                ok: ok,
                summary: ok
                    ? "provider_probe=ok route=\(route.kind.rawValue) \(result)"
                    : "provider_probe=failed route=\(route.kind.rawValue) \(oneLine(result))"
            )
        } catch {
            return ProviderProbeResult(
                configured: true,
                ok: false,
                summary: "provider_probe=failed route=\(route.kind.rawValue) host=\(route.hostDescription) error=\(oneLine(error.localizedDescription))"
            )
        }
    }

    static func runSelfTest() -> String {
        let previousBaseURL = UserDefaults.standard.string(forKey: baseURLKey)
        let previousAPIKey = readAPIKey()
        defer {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
            deleteAPIKey()
            if let previousBaseURL {
                UserDefaults.standard.set(previousBaseURL, forKey: baseURLKey)
            }
            if let previousAPIKey {
                try? saveAPIKey(previousAPIKey)
            }
        }

        do {
            clear()
            let requiredSummary = AIProviderRouting.projectRouteSummary
            let requiredGateOK = AIProviderRouting.projectRoute == nil
                && requiredSummary.contains("project_ai_route=oases_default")
                && requiredSummary.contains("oases_endpoint_active=1")

            try save(baseURLString: "https://provider.example/v1", apiKey: "selftest-key")
            guard let route = AIProviderRouting.projectRoute else {
                return "ai_provider_settings_failed missing_project_route"
            }
            let summary = AIProviderRouting.projectRouteSummary
            let parserSummary = parseModelsResponse(Data(#"{"data":[{"id":"model-alpha"},{"id":"model-beta"}]}"#.utf8))
            let ok = route.kind == .inAppProjectProvider
                && route.hostDescription == "provider.example"
                && route.apiKey == "selftest-key"
                && summary.contains("custom_provider_active=1")
                && summary.contains("oases_endpoint_active=0")
                && requiredGateOK
                && parserSummary == "models=2 first_model=model-alpha"
            return ok ? "ai_provider_settings_ok \(requiredSummary) \(summary) provider_optional_override_ok provider_models_parser_ok" : "ai_provider_settings_failed \(requiredSummary) \(summary) \(parserSummary)"
        } catch {
            return "ai_provider_settings_failed \(error.localizedDescription)"
        }
    }

    enum SettingsError: LocalizedError {
        case invalidBaseURL
        case directProviderNotConfigured
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return String(localized: "请输入有效的 HTTP/HTTPS Base URL，例如 https://api.example.com/v1。", comment: "Validation error for the custom AI provider base URL field")
            case .directProviderNotConfigured:
                return String(localized: "尚未配置自定义工程模式 AI Provider；不配置时会使用 Oases 默认模型端点。", comment: "Error: no custom AI provider configured for Ogent; the default Oases endpoint is used")
            case .keychain(let status):
                return String(localized: "Keychain 保存失败：\(status)", comment: "Error: saving to the Keychain failed; argument is the OSStatus code")
            }
        }
    }

    private static func parseModelsResponse(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else {
            return "models=unknown first_model=unknown"
        }
        let firstID = models
            .compactMap { $0["id"] as? String }
            .first
            .map(redactModelID) ?? "unknown"
        return "models=\(models.count) first_model=\(firstID)"
    }

    private static func redactModelID(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(80))
    }

    private static func oneLine(_ value: String, limit: Int = 240) -> String {
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(limit))
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readAPIKey() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func saveAPIKey(_ value: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SettingsError.keychain(updateStatus)
            }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SettingsError.keychain(addStatus)
            }
        } else {
            throw SettingsError.keychain(status)
        }
    }

    private static func deleteAPIKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
