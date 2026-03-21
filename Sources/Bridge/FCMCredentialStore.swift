import Foundation
#if canImport(Security)
import Security
#endif

/// Manages FCM (Firebase Cloud Messaging) credentials in the macOS Keychain.
///
/// Stores two credential sets:
/// - **Firebase config**: project ID, API key, sender ID, app ID — extracted from
///   `google-services.json` and sent to Android during pairing so it can initialize
///   Firebase at runtime without baking credentials into the APK.
/// - **Service account**: The full service account JSON — used by `FCMDispatcher`
///   to generate OAuth2 access tokens for the FCM v1 HTTP API.
///
/// Thread-safe via `NSLock`. Singleton: access via `FCMCredentialStore.shared`.
final class FCMCredentialStore: @unchecked Sendable {
    static let shared = FCMCredentialStore()

    // MARK: - Types

    /// Firebase config fields needed by the Android app to initialize Firebase at runtime.
    struct FirebaseConfig: Codable, Equatable {
        let projectId: String
        let apiKey: String
        let senderId: String
        let appId: String
    }

    /// Service account fields needed for OAuth2 token generation.
    struct ServiceAccount: Codable {
        let type: String
        let projectId: String
        let privateKeyId: String
        let privateKey: String
        let clientEmail: String
        let tokenUri: String

        enum CodingKeys: String, CodingKey {
            case type
            case projectId = "project_id"
            case privateKeyId = "private_key_id"
            case privateKey = "private_key"
            case clientEmail = "client_email"
            case tokenUri = "token_uri"
        }
    }

    // MARK: - Constants

    private static let keychainService = "com.cmux.fcm"
    private static let firebaseConfigAccount = "firebase-config"
    private static let serviceAccountAccount = "service-account"

    // MARK: - State

    private let lock = NSLock()
    private var cachedFirebaseConfig: FirebaseConfig?
    private var cachedServiceAccount: ServiceAccount?

    private init() {}

    // MARK: - Firebase Config (google-services.json)

    /// Imports Firebase config from a `google-services.json` file.
    ///
    /// Extracts the project ID, API key, sender ID, and app ID from the JSON
    /// structure and stores them in the Keychain.
    ///
    /// - Parameter fileURL: Path to the `google-services.json` file.
    /// - Throws: If the file cannot be read or doesn't contain the expected fields.
    func importConfig(fromFile fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FCMCredentialError.invalidFormat("Not a JSON object")
        }

        // google-services.json structure:
        // { "project_info": { "project_number": "...", "project_id": "..." },
        //   "client": [{ "client_info": { "mobilesdk_app_id": "..." },
        //                "api_key": [{ "current_key": "..." }] }] }
        guard let projectInfo = json["project_info"] as? [String: Any],
              let projectId = projectInfo["project_id"] as? String,
              let senderId = projectInfo["project_number"] as? String else {
            throw FCMCredentialError.invalidFormat("Missing project_info.project_id or project_number")
        }

        guard let clients = json["client"] as? [[String: Any]],
              let firstClient = clients.first else {
            throw FCMCredentialError.invalidFormat("Missing client array")
        }

        guard let clientInfo = firstClient["client_info"] as? [String: Any],
              let appId = clientInfo["mobilesdk_app_id"] as? String else {
            throw FCMCredentialError.invalidFormat("Missing client_info.mobilesdk_app_id")
        }

        guard let apiKeys = firstClient["api_key"] as? [[String: Any]],
              let firstKey = apiKeys.first,
              let apiKey = firstKey["current_key"] as? String else {
            throw FCMCredentialError.invalidFormat("Missing api_key[0].current_key")
        }

        let config = FirebaseConfig(
            projectId: projectId,
            apiKey: apiKey,
            senderId: senderId,
            appId: appId
        )

        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let configData = try encoder.encode(config)
        saveToKeychain(data: configData, account: FCMCredentialStore.firebaseConfigAccount)
        cachedFirebaseConfig = config
    }

    /// Returns the stored Firebase config, or `nil` if not yet imported.
    func getFirebaseConfig() -> FirebaseConfig? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedFirebaseConfig {
            return cached
        }
        guard let data = loadFromKeychain(account: FCMCredentialStore.firebaseConfigAccount) else {
            return nil
        }
        let config = try? JSONDecoder().decode(FirebaseConfig.self, from: data)
        cachedFirebaseConfig = config
        return config
    }

    // MARK: - Service Account

    /// Imports an FCM service account from a JSON key file.
    ///
    /// - Parameter fileURL: Path to the service account JSON file downloaded from
    ///   the Google Cloud Console.
    /// - Throws: If the file cannot be read or is not a valid service account key.
    func importServiceAccount(fromFile fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)

        // Validate that it parses as a service account before storing.
        let decoder = JSONDecoder()
        let account = try decoder.decode(ServiceAccount.self, from: data)

        guard account.type == "service_account" else {
            throw FCMCredentialError.invalidFormat("JSON type is '\(account.type)', expected 'service_account'")
        }

        lock.lock()
        defer { lock.unlock() }

        // Store the raw JSON (not re-encoded) so all fields are preserved.
        saveToKeychain(data: data, account: FCMCredentialStore.serviceAccountAccount)
        cachedServiceAccount = account
    }

    /// Returns the stored service account, or `nil` if not yet imported.
    func getServiceAccount() -> ServiceAccount? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedServiceAccount {
            return cached
        }
        guard let data = loadFromKeychain(account: FCMCredentialStore.serviceAccountAccount) else {
            return nil
        }
        let account = try? JSONDecoder().decode(ServiceAccount.self, from: data)
        cachedServiceAccount = account
        return account
    }

    /// Returns `true` if both Firebase config and service account are stored.
    func isConfigured() -> Bool {
        return getFirebaseConfig() != nil && getServiceAccount() != nil
    }

    // MARK: - Keychain Operations

    private func loadFromKeychain(account: String) -> Data? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: FCMCredentialStore.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            NSLog("[FCMCredentialStore] Keychain read for account '%@' status=%d (0=success, -25300=notFound)", account, status)
            return nil
        }
        NSLog("[FCMCredentialStore] Keychain read for account '%@' succeeded, %d bytes", account, data.count)
        return data
#else
        return nil
#endif
    }

    private func saveToKeychain(data: Data, account: String) {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: FCMCredentialStore.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[FCMCredentialStore] Keychain add failed for account '%@' with status %d", account, addStatus)
            }
        } else if updateStatus != errSecSuccess {
            NSLog("[FCMCredentialStore] Keychain update failed for account '%@' with status %d", account, updateStatus)
        }
#endif
    }
}

// MARK: - Errors

enum FCMCredentialError: Error, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "Invalid credential format: \(detail)"
        }
    }
}
