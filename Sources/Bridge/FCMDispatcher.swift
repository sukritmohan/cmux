import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Dispatches push notifications via Firebase Cloud Messaging v1 HTTP API.
///
/// Loads credentials from `FCMCredentialStore`, generates OAuth2 access tokens
/// using the service account's RSA private key, and sends HTTP POST requests
/// to the FCM endpoint.
///
/// **Dual delivery strategy**: Skips devices that are currently connected via
/// WebSocket (notifications arrive instantly via the existing event relay).
/// Only sends FCM pushes to devices that are disconnected.
///
/// **Rate limiting**: Coalesces rapid notifications — max one push per device
/// per 5 seconds.
///
/// All network operations run on a background `DispatchQueue`.
final class FCMDispatcher: @unchecked Sendable {
    static let shared = FCMDispatcher()

    // MARK: - State

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.cmux.fcm-dispatcher", qos: .utility)

    /// Cached OAuth2 access token and its expiry time.
    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date = .distantPast

    /// Tracks the last push time per device to enforce rate limiting.
    /// Keyed by device UUID.
    private var lastPushTime: [UUID: Date] = [:]

    /// Minimum interval between pushes to the same device.
    private static let rateLimitInterval: TimeInterval = 5.0

    private init() {}

    // MARK: - Public API

    /// Sends a push notification to all paired devices that are not currently
    /// connected via WebSocket.
    ///
    /// - Parameters:
    ///   - title: The notification title.
    ///   - body: The notification body text.
    ///   - data: Additional data payload (workspace_id, surface_id, reason).
    func notifyAllDevices(title: String, body: String, data: [String: String] = [:]) {
        queue.async { [weak self] in
            self?._notifyAllDevices(title: title, body: body, data: data)
        }
    }

    /// Sends a test notification to all paired devices (ignores WebSocket connection status).
    func sendTestNotification() {
        queue.async { [weak self] in
            guard let self else { return }
            let devices = BridgeAuth.shared.listDevices()
            for device in devices {
                guard let fcmToken = device.fcmToken else { continue }
                self._send(to: fcmToken, title: "cmux Test", body: "Push notifications are working!", data: [:])
            }
        }
    }

    // MARK: - Private

    private func _notifyAllDevices(title: String, body: String, data: [String: String]) {
        let connectedIds = BridgeServer.shared.connectedDeviceIds()
        let devices = BridgeAuth.shared.listDevices()
        let now = Date()

        NSLog("[FCMDispatcher] notifyAllDevices: %d devices, %d connected, connectedIds=%@",
              devices.count, connectedIds.count,
              connectedIds.map { $0.uuidString.prefix(8) }.joined(separator: ","))

        for device in devices {
            let hasToken = device.fcmToken != nil
            let isConnected = connectedIds.contains(device.id)
            NSLog("[FCMDispatcher]   device=%@ name=%@ hasToken=%d isConnected=%d",
                  String(device.id.uuidString.prefix(8)), device.name, hasToken ? 1 : 0, isConnected ? 1 : 0)

            // Skip devices with active WebSocket connections — they get real-time events.
            if isConnected { continue }

            // Skip devices without FCM tokens.
            guard let fcmToken = device.fcmToken else { continue }

            // Rate limit: skip if we pushed to this device within the last 5 seconds.
            lock.lock()
            let lastPush = lastPushTime[device.id]
            lock.unlock()

            if let lastPush, now.timeIntervalSince(lastPush) < FCMDispatcher.rateLimitInterval {
                NSLog("[FCMDispatcher]   SKIPPED (rate limit) device=%@", String(device.id.uuidString.prefix(8)))
                continue
            }

            // Record push time before sending (optimistic).
            lock.lock()
            lastPushTime[device.id] = now
            lock.unlock()

            NSLog("[FCMDispatcher]   SENDING FCM to device=%@ token=%@...",
                  String(device.id.uuidString.prefix(8)), String(fcmToken.prefix(20)))
            _send(to: fcmToken, title: title, body: body, data: data)
        }
    }

    private func _send(to fcmToken: String, title: String, body: String, data: [String: String]) {
        guard let serviceAccount = FCMCredentialStore.shared.getServiceAccount() else {
            NSLog("[FCMDispatcher] No service account configured, skipping push")
            return
        }

        guard let accessToken = getAccessToken(serviceAccount: serviceAccount) else {
            NSLog("[FCMDispatcher] Failed to obtain access token")
            return
        }

        let projectId = serviceAccount.projectId
        let urlString = "https://fcm.googleapis.com/v1/projects/\(projectId)/messages:send"
        guard let url = URL(string: urlString) else { return }

        // Build FCM v1 message payload.
        var messageData = data
        messageData["title"] = title

        let payload: [String: Any] = [
            "message": [
                "token": fcmToken,
                "notification": [
                    "title": title,
                    "body": body,
                ],
                "data": messageData,
                "android": [
                    "priority": "high",
                ],
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            NSLog("[FCMDispatcher] Failed to serialize FCM payload")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let task = URLSession.shared.dataTask(with: request) { responseData, response, error in
            if let error {
                NSLog("[FCMDispatcher] HTTP error: %@", error.localizedDescription)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode < 200 || statusCode >= 300 {
                let body = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("[FCMDispatcher] FCM API error %d: %@", statusCode, body)
            }
        }
        task.resume()
    }

    // MARK: - OAuth2 Access Token

    /// Returns a valid OAuth2 access token, using the cached one if still valid.
    private func getAccessToken(serviceAccount: FCMCredentialStore.ServiceAccount) -> String? {
        lock.lock()
        if let cached = cachedAccessToken, Date() < tokenExpiresAt {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Generate a new access token via JWT exchange.
        guard let jwt = generateJWT(serviceAccount: serviceAccount) else {
            return nil
        }

        guard let token = exchangeJWTForToken(jwt: jwt, tokenUri: serviceAccount.tokenUri) else {
            return nil
        }

        lock.lock()
        cachedAccessToken = token
        // Google access tokens are valid for 3600 seconds; refresh 5 minutes early.
        tokenExpiresAt = Date().addingTimeInterval(3300)
        lock.unlock()

        return token
    }

    /// Generates a signed JWT for the Google OAuth2 token exchange.
    ///
    /// The JWT is signed with the service account's RSA private key using RS256.
    private func generateJWT(serviceAccount: FCMCredentialStore.ServiceAccount) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let expiry = now + 3600

        // JWT Header
        let header: [String: String] = [
            "alg": "RS256",
            "typ": "JWT",
            "kid": serviceAccount.privateKeyId,
        ]

        // JWT Claims
        let claims: [String: Any] = [
            "iss": serviceAccount.clientEmail,
            "sub": serviceAccount.clientEmail,
            "aud": serviceAccount.tokenUri,
            "iat": now,
            "exp": expiry,
            "scope": "https://www.googleapis.com/auth/firebase.messaging",
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let claimsData = try? JSONSerialization.data(withJSONObject: claims) else {
            return nil
        }

        let headerB64 = base64URLEncode(headerData)
        let claimsB64 = base64URLEncode(claimsData)
        let signingInput = "\(headerB64).\(claimsB64)"

        guard let signatureData = rsaSign(data: Data(signingInput.utf8),
                                          privateKeyPEM: serviceAccount.privateKey) else {
            NSLog("[FCMDispatcher] RSA signing failed")
            return nil
        }

        let signatureB64 = base64URLEncode(signatureData)
        return "\(signingInput).\(signatureB64)"
    }

    /// Exchanges a signed JWT for an OAuth2 access token via Google's token endpoint.
    private func exchangeJWTForToken(jwt: String, tokenUri: String) -> String? {
        guard let url = URL(string: tokenUri) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)

        // Synchronous request on background queue — acceptable for token exchange.
        let semaphore = DispatchSemaphore(value: 0)
        var accessToken: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                NSLog("[FCMDispatcher] Token exchange error: %@", error.localizedDescription)
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("[FCMDispatcher] Token exchange failed: %@", body)
                return
            }

            accessToken = token
        }
        task.resume()
        semaphore.wait()

        return accessToken
    }

    // MARK: - RSA Signing

    /// Signs data with an RSA private key using SHA-256 (RS256).
    ///
    /// Uses Security.framework's `SecKeyCreateSignature` for the actual signing.
    private func rsaSign(data: Data, privateKeyPEM: String) -> Data? {
#if canImport(Security)
        guard let privateKey = loadRSAPrivateKey(pem: privateKeyPEM) else {
            NSLog("[FCMDispatcher] Failed to load RSA private key from PEM")
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            if let error = error?.takeRetainedValue() {
                NSLog("[FCMDispatcher] RSA sign error: %@", error.localizedDescription)
            }
            return nil
        }

        return signature
#else
        return nil
#endif
    }

    /// Loads an RSA private key from a PEM-encoded string.
    ///
    /// Google service account keys use PKCS#8 format (`BEGIN PRIVATE KEY`), which
    /// wraps the RSA key in an ASN.1 `PrivateKeyInfo` structure. `SecKeyCreateWithData`
    /// expects raw PKCS#1 RSA key data, so we strip the 26-byte PKCS#8 header.
    private func loadRSAPrivateKey(pem: String) -> SecKey? {
#if canImport(Security)
        let isPKCS8 = pem.contains("BEGIN PRIVATE KEY")

        // Strip PEM header/footer and whitespace.
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard var keyData = Data(base64Encoded: stripped) else {
            NSLog("[FCMDispatcher] Failed to base64 decode private key")
            return nil
        }

        // PKCS#8 wraps the RSA key in an ASN.1 PrivateKeyInfo structure.
        // Strip the 26-byte header to get the raw PKCS#1 RSA private key
        // that SecKeyCreateWithData expects.
        if isPKCS8 && keyData.count > 26 {
            keyData = keyData.subdata(in: 26..<keyData.count)
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]

        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error)
        if key == nil, let error = error?.takeRetainedValue() {
            NSLog("[FCMDispatcher] SecKeyCreateWithData error: %@", error.localizedDescription)
        }
        return key
#else
        return nil
#endif
    }

    // MARK: - Helpers

    /// Base64 URL-safe encoding (no padding) per RFC 4648 section 5.
    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
