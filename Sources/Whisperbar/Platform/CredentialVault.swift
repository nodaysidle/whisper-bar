import Foundation
import Security

// MARK: - Credential identity

/// The deterministic provider-account keys from CON-DATA-API-CREDENTIAL.
enum CredentialKey: String, CaseIterable, Codable, Sendable {
    case deepgramNovaStreamingTranscription = "deepgram-nova-streaming-transcription-api-key"
    case openRouter = "openrouter-api-key"

    /// Keychain account name (TRD "Keychain account").
    var account: String { rawValue }

    var displayName: String {
        switch self {
        case .deepgramNovaStreamingTranscription: return "Deepgram"
        case .openRouter: return "OpenRouter"
        }
    }
}

// MARK: - Storage seam

/// Errors surfaced by a Keychain store implementation. These never carry
/// secret material: only an OSStatus class.
enum KeychainStoreError: Error, Equatable, Sendable {
    case readFailed(Int32)
    case writeFailed(Int32)
    case deleteFailed(Int32)
}

/// Injectable boundary around SecItem so tests never touch the live Keychain.
protocol KeychainStoring: Sendable {
    func read(account: String, service: String) throws -> String?
    func store(value: String, account: String, service: String) throws
    func delete(account: String, service: String) throws
}

/// Live macOS Keychain implementation. Credentials are generic passwords owned
/// by the locked service name and stored with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they never leave the device.
struct SecItemKeychainStore: KeychainStoring {

    func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read(account: String, service: String) throws -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.readFailed(errSecInvalidData)
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.readFailed(status)
        }
    }

    func store(value: String, account: String, service: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account, service: service)

        // Replacement path: update the existing item in place so a failure
        // leaves the prior value untouched.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.writeFailed(updateStatus)
        }

        // Insert path: first write for this account.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.writeFailed(addStatus)
        }
    }

    func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.deleteFailed(status)
        }
    }
}

// MARK: - Vault errors and status

/// Privacy-safe vault failures. Messages carry only the provider name and an
/// operation category; secret material never appears in an error value.
enum CredentialVaultError: Error, Equatable, Sendable {
    case invalidValue(CredentialKey)
    case unreadable(CredentialKey)
    case storeFailed(CredentialKey)
    case replacementFailed(CredentialKey)
    case deletionFailed(CredentialKey)

    var userFacingMessage: String {
        switch self {
        case .invalidValue(let key):
            return "The \(key.displayName) API key is empty. Enter a key and try again."
        case .unreadable(let key):
            return "The stored \(key.displayName) API key could not be read from the Keychain."
        case .storeFailed(let key):
            return "The \(key.displayName) API key could not be saved to the Keychain. Nothing was stored."
        case .replacementFailed(let key):
            return "The \(key.displayName) API key could not be replaced. The previous key is unchanged."
        case .deletionFailed(let key):
            return "The \(key.displayName) API key could not be removed from the Keychain."
        }
    }
}

/// Non-throwing credential view used by presentation and feature owners.
enum CredentialStatus: Equatable, Sendable {
    case missing
    case configured
    case unavailable(reason: CredentialVaultError)
}

// MARK: - CredentialVault

/// CON-DATA-API-CREDENTIAL / CON-CREDENTIAL-* owner.
///
/// CredentialVault exclusively owns credential storage, retrieval,
/// replacement, and deletion; DataStore receives no secret value. The actor
/// boundary serializes Keychain work off the main actor and every failure is
/// mapped to a privacy-safe, provider-scoped error.
actor CredentialVault {
    private let store: KeychainStoring
    private let service: String

    init(store: KeychainStoring = SecItemKeychainStore(), service: String = AppIdentity.keychainService) {
        self.store = store
        self.service = service
    }

    /// Rejects empty/whitespace-only input so a missing credential is never
    /// silently "saved" as an unusable empty string.
    func store(_ key: CredentialKey, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CredentialVaultError.invalidValue(key)
        }
        do {
            try store.store(value: value, account: key.account, service: service)
        } catch {
            // Classify against the still-valid prior state: a failed write while
            // a prior value exists is a replacement failure and the prior value
            // remains in place (the store updates in place and never clears first).
            var hadPriorValue = false
            if let existing = try? store.read(account: key.account, service: service) {
                hadPriorValue = !existing.isEmpty
            }
            throw hadPriorValue
                ? CredentialVaultError.replacementFailed(key)
                : CredentialVaultError.storeFailed(key)
        }
    }

    func value(for key: CredentialKey) throws -> String? {
        do {
            return try store.read(account: key.account, service: service)
        } catch {
            throw CredentialVaultError.unreadable(key)
        }
    }

    func hasValue(for key: CredentialKey) throws -> Bool {
        try value(for: key) != nil
    }

    func delete(_ key: CredentialKey) throws {
        do {
            try store.delete(account: key.account, service: service)
        } catch {
            throw CredentialVaultError.deletionFailed(key)
        }
    }

    func status(for key: CredentialKey) -> CredentialStatus {
        do {
            return try hasValue(for: key) ? .configured : .missing
        } catch let vaultError as CredentialVaultError {
            return .unavailable(reason: vaultError)
        } catch {
            return .unavailable(reason: .unreadable(key))
        }
    }

    /// Clear, value-free message used by feature owners when a provider action
    /// must be blocked (ACC-CREDENTIAL-VAULT-04).
    static func blockingMessage(for key: CredentialKey, status: CredentialStatus) -> String? {
        switch status {
        case .configured:
            return nil
        case .missing:
            return "Add a \(key.displayName) API key in Settings before using this provider."
        case .unavailable:
            return "The \(key.displayName) API key is unavailable right now. Open Settings to retry."
        }
    }
}
