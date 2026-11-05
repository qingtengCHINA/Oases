import Foundation
import CryptoKit
import DeviceCheck
import Security

/// Binds this app's API traffic to an Apple App Attest device key.
/// Enrollment happens once per install; every request is then signed with the
/// device private key (assertion) so the Oases gateway can prove the caller is
/// the genuine app. The API key alone is no longer enough to call the API.
final class AttestationClient: Sendable {
    static let shared = AttestationClient()
    private init() {}

    /// 软件标识：必须与服务端 permissions.json 中该 API key 的
    /// policy.attestation.app_id 完全一致，否则 enroll / 验签会报 app_id_mismatch。
    static let appID = "oaseschat"

    struct Config: Sendable {
        let baseURL: String   // e.g. "https://api.oases.dev"
        let apiKey: String    // 该软件专属 key（attestation.required 的那种）
        let appId: String     // 与服务端 policy.attestation.app_id 完全一致
    }

    enum AttestError: LocalizedError {
        case unsupported
        case notConfigured
        case httpError(Int, String)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "App Attest is not supported on this device"
            case .notConfigured: return "AttestationClient.configure() was not called"
            case .httpError(let code, let msg): return "Attestation HTTP \(code): \(msg)"
            }
        }
    }

    nonisolated(unsafe) private let service = DCAppAttestService.shared
    private let log = AppLogger(category: "Attest")
    private let lock = NSLock()
    nonisolated(unsafe) private var config: Config?
    nonisolated(unsafe) private var cachedKeyId: String?
    nonisolated(unsafe) private var enrollment: Task<String, Error>?

    private static let keychainAccount = "dev.oases.attest.keyId"

    // MARK: - Public API

    func configure(_ cfg: Config) {
        lock.lock(); defer { lock.unlock() }
        config = cfg
        cachedKeyId = Self.keychainLoad()
        log.info("configured appId=\(cfg.appId) keyIdCached=\(cachedKeyId != nil) supported=\(service.isSupported)")
    }

    /// Signed headers for one API request. Call per request, right before sending.
    func signedHeaders(method: String, path: String, body: Data?) async throws -> [String: String] {
        let keyId = try await ensureEnrolled()
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let bodyHash = SHA256.hash(data: body ?? Data())
            .map { String(format: "%02x", $0) }.joined()
        let clientData = "\(bodyHash)\n\(timestamp)\n\(method.uppercased())\n\(path)"
        let clientDataHash = Data(SHA256.hash(data: Data(clientData.utf8)))
        log.debug("sign clientData=\(clientData)")
        do {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            return [
                "X-Oases-KeyId": keyId,
                "X-Oases-Timestamp": timestamp,
                "X-Oases-Assertion": assertion.base64EncodedString(),
            ]
        } catch {
            // Dangling keyId: our Keychain entry can survive an app delete while
            // the Secure Enclave key it names does not — signing then fails with
            // a DeviceCheck error. Drop the stale enrollment, enroll a fresh key
            // and retry exactly once; a second failure degrades to unsigned.
            log.warning("generateAssertion failed (\(error.localizedDescription)) — re-enrolling and retrying once")
            resetEnrollment()
            let freshKeyId = try await ensureEnrolled()
            let assertion = try await service.generateAssertion(freshKeyId, clientDataHash: clientDataHash)
            return [
                "X-Oases-KeyId": freshKeyId,
                "X-Oases-Timestamp": timestamp,
                "X-Oases-Assertion": assertion.base64EncodedString(),
            ]
        }
    }

    /// 401 self-heal: call this when the server answers device_not_enrolled,
    /// then retry the request once.
    func resetEnrollment() {
        lock.lock(); defer { lock.unlock() }
        cachedKeyId = nil
        enrollment = nil
        Self.keychainDelete()
    }

    // MARK: - Enrollment

    private func ensureEnrolled() async throws -> String {
        guard service.isSupported else {
            log.warning("DCAppAttestService.isSupported == false, signing skipped")
            throw AttestError.unsupported
        }
        lock.lock()
        guard let cfg = config else {
            lock.unlock()
            log.warning("not configured, signing skipped")
            throw AttestError.notConfigured
        }
        if let keyId = cachedKeyId {
            lock.unlock()
            return keyId
        }
        if let task = enrollment {
            lock.unlock()
            return try await task.value
        }
        log.info("enroll begin (generateKey…)")
        let task = Task { [service] in
            let keyId: String
            do {
                keyId = try await service.generateKey()
            } catch {
                self.log.error("generateKey failed: \(error.localizedDescription)")
                throw error
            }
            let nonce: String
            do {
                nonce = try await self.fetchNonce(cfg)
            } catch {
                self.log.error("fetchNonce failed: \(error.localizedDescription)")
                throw error
            }
            let clientDataHash = Data(SHA256.hash(data: Data(nonce.utf8)))
            let attestation: Data
            do {
                attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            } catch {
                self.log.error("attestKey failed: \(error.localizedDescription)")
                throw error
            }

            var request = URLRequest(url: URL(string: "\(cfg.baseURL)/v1/attest/enroll")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "app_id": cfg.appId,
                "key_id": keyId,
                "attestation": attestation.base64EncodedString(),
                "nonce": nonce,
            ])
            let (data, response) = try await AIRequestGate.data(URLSession.shared, for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                self.log.error("enroll HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
                throw AttestError.httpError(status, String(data: data, encoding: .utf8) ?? "")
            }

            self.lock.lock()
            self.cachedKeyId = keyId
            Self.keychainSave(keyId)
            self.lock.unlock()
            self.log.info("enroll OK keyId=\(keyId.prefix(8))…")
            return keyId
        }
        enrollment = task
        lock.unlock()
        do {
            return try await task.value
        } catch {
            // 失败时清掉 in-flight 记录，下一次调用可以重新 enroll。
            lock.lock()
            enrollment = nil
            lock.unlock()
            throw error
        }
    }

    private func fetchNonce(_ cfg: Config) async throws -> String {
        var request = URLRequest(url: URL(string: "\(cfg.baseURL)/v1/attest/nonce")!)
        request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await AIRequestGate.data(URLSession.shared, for: request)
        guard (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = json["nonce"] as? String else {
            throw AttestError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0,
                                        String(data: data, encoding: .utf8) ?? "")
        }
        return nonce
    }

    // MARK: - Keychain (keyId 持久化)

    private static func keychainSave(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = value.data(using: .utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainLoad() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
