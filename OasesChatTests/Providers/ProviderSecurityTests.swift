import Foundation
import XCTest
@testable import Oases_Chat

/// Code-review remediation (package F): OAuth callback server, OpenRouter
/// state, OAuth token Keychain accessibility, chat-route credential alignment.
final class ProviderSecurityTests: XCTestCase {

    // MARK: - OAuth callback server

    func testCallbackServerBindsLoopbackOnly() throws {
        let server = OAuthCallbackServer(port: Self.randomPort(), callbackPath: "/callback")
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(server.boundAddress(), "127.0.0.1")
        XCTAssertEqual(OAuthCallbackServer.bindAddress, in_addr_t(INADDR_LOOPBACK).bigEndian)
    }

    func testOpenRouterCallbackWithWrongStateIsRejected() async throws {
        let state = OpenRouterOAuthManager.generateState()
        let otherState = OpenRouterOAuthManager.generateState()
        XCTAssertNotEqual(state, otherState)
        let path = OpenRouterOAuthManager.callbackPath(forState: state)
        XCTAssertEqual(path, "/callback/\(state)")

        let port = Self.randomPort()
        let server = OAuthCallbackServer(port: port, callbackPath: path)
        try server.start()
        defer { server.stop() }

        let waiter = Task { try await server.waitForCallback(timeout: 10) }
        // Let waitForCallback register its continuation before any request lands.
        try await Task.sleep(nanoseconds: 300_000_000)

        // A callback minted for a different login (or forged) never resolves this one.
        let forged = try Self.httpGet(port: port, path: OpenRouterOAuthManager.callbackPath(forState: otherState) + "?code=attacker")
        XCTAssertTrue(forged.hasPrefix("HTTP/1.1 404"), forged)
        let bare = try Self.httpGet(port: port, path: "/callback?code=attacker")
        XCTAssertTrue(bare.hasPrefix("HTTP/1.1 404"), bare)

        let genuine = try Self.httpGet(port: port, path: path + "?code=genuine")
        XCTAssertTrue(genuine.hasPrefix("HTTP/1.1 200"), genuine)
        let result = try await waiter.value
        XCTAssertEqual(result.code, "genuine")
    }

    // MARK: - OAuth token Keychain accessibility

    func testLegacySynchronizableOAuthTokenMigratesToDeviceOnly() throws {
        let keychain = InMemoryProviderKeychain()
        let original = ProviderKeychainHelper.backend
        ProviderKeychainHelper.backend = keychain
        defer { ProviderKeychainHelper.backend = original }

        let instanceId = UUID().uuidString
        let service = "dev.oases.chat.ios.provider.\(instanceId)"
        let token = XAITokenStorage(accessToken: "access-1", refreshToken: "refresh-1", idToken: nil,
                                    expireDate: nil, lastRefresh: nil, tokenEndpoint: nil,
                                    email: nil, displayName: nil, accountId: nil)
        // Seed what an older build wrote: a synchronizable item.
        _ = keychain.add([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "oauth-token",
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: try JSONEncoder().encode(token),
        ])

        let loaded = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: XAITokenStorage.self)
        XCTAssertEqual(loaded?.accessToken, "access-1")

        let items = keychain.items(service: service, account: "oauth-token")
        XCTAssertEqual(items.count, 1, "synced copy should be replaced by one device-local item")
        XCTAssertEqual(items.first?.synchronizable, false)
        XCTAssertEqual(items.first?.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        // Reads keep working from the migrated local item.
        XCTAssertEqual(ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: XAITokenStorage.self)?.refreshToken, "refresh-1")
    }

    func testOAuthTokenSavedDeviceOnlyWhileAPIKeysStaySynchronizable() {
        let keychain = InMemoryProviderKeychain()
        let original = ProviderKeychainHelper.backend
        ProviderKeychainHelper.backend = keychain
        defer { ProviderKeychainHelper.backend = original }

        let instanceId = UUID().uuidString
        let service = "dev.oases.chat.ios.provider.\(instanceId)"
        let token = XAITokenStorage(accessToken: "a", refreshToken: "r", idToken: nil, expireDate: nil,
                                    lastRefresh: nil, tokenEndpoint: nil, email: nil, displayName: nil, accountId: nil)
        ProviderKeychainHelper.saveOAuthToken(token, instanceId: instanceId)
        ProviderKeychainHelper.saveAPIKey("sk-test", instanceId: instanceId)

        let tokenItems = keychain.items(service: service, account: "oauth-token")
        XCTAssertEqual(tokenItems.count, 1)
        XCTAssertEqual(tokenItems.first?.synchronizable, false)
        XCTAssertEqual(tokenItems.first?.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        let keyItems = keychain.items(service: service, account: "api-key")
        XCTAssertEqual(keyItems.count, 1)
        XCTAssertEqual(keyItems.first?.synchronizable, true)
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: instanceId), "sk-test")

        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
        XCTAssertTrue(keychain.items(service: service, account: "oauth-token").isEmpty)
    }

    // MARK: - Chat routing vs OAuth logins

    @MainActor
    func testCodexOAuthOnlyInstanceIsNotChatUsableButXAIOAuthIs() {
        let keychain = InMemoryProviderKeychain()
        let original = ProviderKeychainHelper.backend
        ProviderKeychainHelper.backend = keychain
        defer { ProviderKeychainHelper.backend = original }

        let codex = ProviderInstance(label: "Codex", providerType: .openAI, credentialType: .oauth)
        ProviderKeychainHelper.saveOAuthToken(
            CodexTokenStorage(accessToken: "codex", refreshToken: nil, idToken: nil, expireDate: nil,
                              lastRefresh: nil, accountId: nil, planType: nil),
            instanceId: codex.id
        )
        XCTAssertTrue(codex.computeHasAnyCredential())
        XCTAssertFalse(ProviderChatRouting.canServeChat(codex),
                       "a ChatGPT login can't ride the chat-completions route")

        let xai = ProviderInstance(label: "Grok", providerType: .xAI, credentialType: .oauth)
        ProviderKeychainHelper.saveOAuthToken(
            XAITokenStorage(accessToken: "grok", refreshToken: nil, idToken: nil,
                            expireDate: Date().addingTimeInterval(3600), lastRefresh: nil,
                            tokenEndpoint: nil, email: nil, displayName: nil, accountId: nil),
            instanceId: xai.id
        )
        XCTAssertTrue(ProviderChatRouting.canServeChat(xai))

        // A manual bearer token makes the Codex instance routable again.
        ProviderKeychainHelper.saveOAuthString("manual", instanceId: codex.id, account: "manual-oauth-token")
        XCTAssertTrue(ProviderChatRouting.canServeChat(codex))
    }

    // MARK: - Helpers

    private static func randomPort() -> UInt16 {
        UInt16.random(in: 42_000...58_000)
    }

    /// Minimal blocking HTTP/1.1 GET against 127.0.0.1 over a BSD socket.
    private static func httpGet(port: UInt16, path: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
        }
        return String(data: response, encoding: .utf8) ?? ""
    }
}

/// In-memory stand-in for the SecItem API with the synchronizable-matching
/// rules `ProviderKeychainHelper` relies on: a query without
/// `kSecAttrSynchronizable` matches only non-synchronizable items, `true`
/// matches only synchronizable ones, `kSecAttrSynchronizableAny` matches both.
final class InMemoryProviderKeychain: ProviderKeychainBackend, @unchecked Sendable {
    struct Item {
        let service: String
        let account: String
        let synchronizable: Bool
        let accessible: String?
        let data: Data
    }

    private let lock = NSLock()
    private var storage: [Item] = []

    func items(service: String, account: String) -> [Item] {
        lock.withLock { storage.filter { $0.service == service && $0.account == account } }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        lock.withLock {
            guard let item = storage.first(where: { matches($0, query) }) else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item.data as NSData)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let item = Item(
                service: attributes[kSecAttrService as String] as? String ?? "",
                account: attributes[kSecAttrAccount as String] as? String ?? "",
                synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) == true,
                accessible: attributes[kSecAttrAccessible as String] as? String,
                data: attributes[kSecValueData as String] as? Data ?? Data()
            )
            if storage.contains(where: {
                $0.service == item.service && $0.account == item.account && $0.synchronizable == item.synchronizable
            }) {
                return errSecDuplicateItem
            }
            storage.append(item)
            return errSecSuccess
        }
    }

    @discardableResult
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let before = storage.count
            storage.removeAll { matches($0, query) }
            return storage.count == before ? errSecItemNotFound : errSecSuccess
        }
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        let sync = query[kSecAttrSynchronizable as String]
        if let any = sync as? String, any == (kSecAttrSynchronizableAny as String) { return true }
        let wantsSync = (sync as? Bool) == true
        return item.synchronizable == wantsSync
    }
}
