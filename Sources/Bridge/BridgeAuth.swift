import Darwin
import Foundation
#if canImport(Security)
import Security
#endif

/// Manages device pairing tokens for the cmux-bridge WebSocket server.
///
/// When a user pairs their phone via QR code, a 32-byte random token is generated
/// and stored in the macOS Keychain. The mobile companion app sends this token as
/// `auth.pair` on every WebSocket connection to authenticate.
///
/// Thread-safe via `NSLock` — accessed from WebSocket connection threads,
/// not restricted to MainActor.
///
/// Storage: All paired devices are serialized as a single JSON blob in one Keychain
/// item under the service name `com.cmux.bridge-auth`.
final class BridgeAuth: @unchecked Sendable {
    static let shared = BridgeAuth()

    // MARK: - Types

    /// A device that has been paired with this cmux instance.
    struct PairedDevice: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let token: String
        let createdAt: Date
        var lastSeenAt: Date
    }

    // MARK: - Constants

    /// Keychain service identifier for bridge auth storage.
    static let keychainService = "com.cmux.bridge-auth"

    /// Keychain account identifier (single item stores all devices as JSON).
    private static let keychainAccount = "paired-devices"

    /// Number of random bytes used to generate pairing tokens.
    private static let tokenByteCount = 32

    // MARK: - State

    /// Guards all access to the in-memory device cache and Keychain operations.
    private let lock = NSLock()

    /// In-memory cache of paired devices, lazily loaded from Keychain on first access.
    /// `nil` means "not yet loaded from Keychain".
    private var cachedDevices: [PairedDevice]?

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Creates a new pairing token for a device and stores it in the Keychain.
    ///
    /// - Parameter deviceName: Human-readable name for the device (e.g. "iPhone 15 Pro").
    /// - Returns: The newly created `PairedDevice` with a fresh 32-byte URL-safe base64 token.
    func generatePairing(deviceName: String) -> PairedDevice {
        let tokenBytes = generateRandomBytes(count: BridgeAuth.tokenByteCount)
        let token = urlSafeBase64Encode(tokenBytes)

        let device = PairedDevice(
            id: UUID(),
            name: deviceName,
            token: token,
            createdAt: Date(),
            lastSeenAt: Date()
        )

        lock.lock()
        defer { lock.unlock() }

        var devices = loadDevicesLocked()
        devices.append(device)
        saveDevicesLocked(devices)

        return device
    }

    /// Validates a token against all paired devices using constant-time comparison.
    ///
    /// - Parameter token: The token string sent by the mobile client.
    /// - Returns: The matching `PairedDevice` if the token is valid, `nil` otherwise.
    func validateToken(_ token: String) -> PairedDevice? {
        lock.lock()
        defer { lock.unlock() }

        let devices = loadDevicesLocked()
        return devices.first { constantTimeEqual($0.token, token) }
    }

    /// Updates the `lastSeenAt` timestamp for a device to the current time.
    ///
    /// Called when a paired device reconnects to record activity.
    ///
    /// - Parameter id: The UUID of the device to touch.
    func touchDevice(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var devices = loadDevicesLocked()
        guard let index = devices.firstIndex(where: { $0.id == id }) else {
            return
        }
        devices[index].lastSeenAt = Date()
        saveDevicesLocked(devices)
    }

    /// Removes a paired device and its token from the Keychain.
    ///
    /// - Parameter id: The UUID of the device to revoke.
    func revokeDevice(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var devices = loadDevicesLocked()
        devices.removeAll { $0.id == id }
        saveDevicesLocked(devices)
    }

    /// Returns all currently paired devices.
    ///
    /// - Returns: An array of `PairedDevice` values, possibly empty.
    func listDevices() -> [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }

        return loadDevicesLocked()
    }

    // MARK: - Crypto Helpers (private)

    /// Constant-time string comparison to prevent timing side-channel attacks.
    ///
    /// Uses `timingsafe_bcmp` from Darwin to ensure comparison time is independent
    /// of how many bytes match, preventing token recovery via latency measurement.
    /// Pads to max length to avoid leaking length information via early return.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let maxLen = max(aBytes.count, bBytes.count)
        guard maxLen > 0 else { return true }
        let aPadded = aBytes + [UInt8](repeating: 0, count: maxLen - aBytes.count)
        let bPadded = bBytes + [UInt8](repeating: 0, count: maxLen - bBytes.count)
        // Both content and length must match for a valid token.
        let contentEqual = timingsafe_bcmp(aPadded, bPadded, maxLen) == 0
        let lengthEqual = aBytes.count == bBytes.count
        return contentEqual && lengthEqual
    }

    /// Generates cryptographically random bytes.
    ///
    /// - Parameter count: Number of random bytes to generate.
    /// - Returns: The random bytes as `Data`.
    private func generateRandomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return Data(bytes)
    }

    /// Encodes raw bytes as URL-safe base64 (no padding).
    ///
    /// Replaces `+` with `-`, `/` with `_`, and strips trailing `=` padding
    /// per RFC 4648 section 5.
    ///
    /// - Parameter data: The raw bytes to encode.
    /// - Returns: A URL-safe base64 string.
    private func urlSafeBase64Encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain Operations (must be called with lock held)

    /// Loads the paired device list from the in-memory cache, falling back to Keychain.
    ///
    /// Caller must hold `lock`.
    private func loadDevicesLocked() -> [PairedDevice] {
        if let cached = cachedDevices {
            return cached
        }
        let devices = loadDevicesFromKeychain()
        cachedDevices = devices
        return devices
    }

    /// Persists the device list to Keychain, then updates the in-memory cache.
    ///
    /// Note: cache is always updated regardless of Keychain write outcome. If the
    /// Keychain write fails (logged but not thrown), the cache may diverge from
    /// persisted state until the next app restart. This is acceptable for a desktop
    /// app where Keychain failures are rare.
    /// Caller must hold `lock`.
    private func saveDevicesLocked(_ devices: [PairedDevice]) {
        saveDevicesToKeychain(devices)
        cachedDevices = devices
    }

    /// Reads the paired device list from the macOS Keychain.
    ///
    /// Returns an empty array if the Keychain item does not exist or cannot be decoded.
    private func loadDevicesFromKeychain() -> [PairedDevice] {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: BridgeAuth.keychainService,
            kSecAttrAccount: BridgeAuth.keychainAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                // Log unexpected Keychain errors but don't crash — treat as empty.
                NSLog("[BridgeAuth] Keychain read failed with status %d", status)
            }
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([PairedDevice].self, from: data)
        } catch {
            NSLog("[BridgeAuth] Failed to decode paired devices from Keychain: %@", error.localizedDescription)
            return []
        }
#else
        return []
#endif
    }

    /// Writes the paired device list to the macOS Keychain.
    ///
    /// Creates the Keychain item if it doesn't exist, updates it if it does.
    /// If the device list is empty, deletes the Keychain item entirely to avoid
    /// storing empty data.
    private func saveDevicesToKeychain(_ devices: [PairedDevice]) {
#if canImport(Security)
        // If no devices remain, delete the Keychain item entirely.
        if devices.isEmpty {
            deleteKeychainItem()
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        let data: Data
        do {
            data = try encoder.encode(devices)
        } catch {
            NSLog("[BridgeAuth] Failed to encode paired devices for Keychain: %@", error.localizedDescription)
            return
        }

        // Try to update the existing item first.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: BridgeAuth.keychainService,
            kSecAttrAccount: BridgeAuth.keychainAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it.
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[BridgeAuth] Keychain add failed with status %d", addStatus)
            }
        } else if updateStatus != errSecSuccess {
            NSLog("[BridgeAuth] Keychain update failed with status %d", updateStatus)
        }
#endif
    }

    /// Deletes the paired devices Keychain item.
    ///
    /// Called when all devices have been revoked. Silently succeeds if the item
    /// does not exist (errSecItemNotFound).
    private func deleteKeychainItem() {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: BridgeAuth.keychainService,
            kSecAttrAccount: BridgeAuth.keychainAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("[BridgeAuth] Keychain delete failed with status %d", status)
        }
#endif
    }
}
