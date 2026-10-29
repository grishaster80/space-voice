import Foundation
import Security

/// Reads a JWT's claims without verifying it (only to show the plan and expiry).
private func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// The claude.ai sign-in Claude Code keeps in the login keychain.
enum ClaudeAccount {
    struct Credentials {
        let accessToken: String
        let expiresAt: Date
        /// "pro", "max", "team", "enterprise".
        let subscription: String?

        var isExpired: Bool { expiresAt < Date() }
    }

    private static let service = "Claude Code-credentials"

    /// Whether Claude Code is signed in on this Mac. Looks only at the keychain item's
    /// name, so macOS doesn't ask for permission; the token is read only when dictating with Claude.
    static var isSignedIn: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The sign-in itself. macOS asks the user to allow this the first time.
    static func credentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
        return Credentials(accessToken: token, expiresAt: expiresAt, subscription: oauth["subscriptionType"] as? String)
    }
}

/// The ChatGPT sign-in the Codex CLI keeps in `~/.codex/auth.json`.
enum CodexAccount {
    struct Credentials {
        let accessToken: String
        let accountID: String
        let expiresAt: Date
        /// "plus", "pro", "team", "business", …
        let plan: String?

        var isExpired: Bool { expiresAt < Date() }
    }

    static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    static func credentials() -> Credentials? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String
        else { return nil }
        let expiry = (jwtClaims(token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantFuture
        let auth = (tokens["id_token"] as? String).flatMap(jwtClaims)?["https://api.openai.com/auth"] as? [String: Any]
        return Credentials(accessToken: token, accountID: account, expiresAt: expiry, plan: auth?["chatgpt_plan_type"] as? String)
    }
}
