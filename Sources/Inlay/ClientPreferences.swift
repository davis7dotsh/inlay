import AppKit
import Combine
import Foundation
import Security
import InlayCore

/// Only this Mac's identity and connection live here. Generation state and
/// processing preferences belong to the server.
@MainActor
final class ClientPreferencesStore: ObservableObject {
    private struct Settings: Codable {
        var endpoint: String
        var deviceID: String
        var deviceName: String
    }

    @Published private(set) var endpoint: String
    @Published private(set) var deviceID: String
    @Published private(set) var deviceName: String
    @Published private(set) var token: String
    @Published private(set) var errorMessage: String?
    private let url: URL
    private let credentialAccount: String

    init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         readCredential: ((String) -> String)? = nil) {
        url = root.appendingPathComponent("client.json")
        credentialAccount = root.standardizedFileURL.path
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        let resolvedEndpoint = environment["INLAY_SERVER_URL"] ?? saved?.endpoint ?? "http://127.0.0.1:8391"
        endpoint = resolvedEndpoint
        deviceID = saved?.deviceID ?? UUID().uuidString.lowercased()
        deviceName = saved?.deviceName ?? Host.current().localizedName ?? "My Mac"
        token = ""
        do {
            let validated = try ServerEndpoint(resolvedEndpoint)
            endpoint = validated.address
            let account = credentialAccount + "|" + validated.address
            token = readCredential?(account) ?? Self.readToken(account: account)
            if saved == nil { persist() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(endpoint: String, token: String, deviceName: String) -> Bool {
        let normalizedEndpoint: String
        do { normalizedEndpoint = try ServerEndpoint(endpoint).address }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            errorMessage = "Use a device name between 1 and 120 characters."
            return false
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken.utf8.count <= 4_096, !trimmedToken.contains(where: \.isWhitespace) else {
            errorMessage = "Use a server token without whitespace, up to 4 KB."
            return false
        }
        // Scope credentials to their exact endpoint so a failed settings write
        // or environment override cannot send one server's key to another.
        guard Self.writeToken(trimmedToken, account: credentialAccount + "|" + normalizedEndpoint) else {
            errorMessage = "The server credential could not be saved in Keychain."
            return false
        }
        let previous = (self.endpoint, self.deviceName, self.token)
        self.endpoint = normalizedEndpoint
        self.deviceName = name
        self.token = trimmedToken
        guard persist() else {
            (self.endpoint, self.deviceName, self.token) = previous
            return false
        }
        return true
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Settings(endpoint: endpoint, deviceID: deviceID, deviceName: deviceName))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save device preferences: \(error.localizedDescription)"
            return false
        }
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: InlayBuild.current.credentialService,
         kSecAttrAccount as String: account]
    }

    private static func readToken(account: String) -> String {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func writeToken(_ token: String, account: String) -> Bool {
        let query = keychainQuery(account: account)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }
}
