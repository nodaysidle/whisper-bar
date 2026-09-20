import Foundation

// MARK: - Connection test outcome

/// Value-free outcome of an explicit credential connection test.
enum CredentialConnectionOutcome: Equatable, Sendable {
    case verified(requestID: String?)
    case missingCredential
    case failed(String)
    case notAvailable(String)
}

// MARK: - CredentialVaultFeature

/// OWN-CREDENTIAL-VAULT-FEATURE.
///
/// Owns CON-CREDENTIAL-VAULT-INTERFACE and CON-CREDENTIAL-VAULT-RECOVERY: the
/// settings-facing credential surface. Credentials are stored only in the
/// macOS Keychain through `CredentialVault`; updates are atomic because the
/// vault replaces in place and never clears first; every failure is mapped to
/// a privacy-safe, provider-scoped message that never contains the secret; and
/// missing credentials block only the affected provider action with a clear
/// message. Recovery is an explicit replacement, deletion, or connection retry
/// that preserves the last valid state.
@MainActor
final class CredentialVaultFeature {

    // MARK: States

    enum FailureCategory: String, Equatable, Sendable {
        case invalidValue
        case storeFailed
        case replacementFailed
        case deletionFailed
        case unreadable
    }

    struct Failure: Equatable, Sendable {
        let category: FailureCategory
        let key: CredentialKey
        let message: String
    }

    enum Action: Equatable, Sendable {
        case stored(CredentialKey)
        case replaced(CredentialKey)
        case deleted(CredentialKey)
    }

    // MARK: Observable state

    /// Value-free provider status cache; it never contains secret material.
    private(set) var statuses: [CredentialKey: CredentialStatus] = [:]
    private(set) var lastFailure: Failure?
    private(set) var lastAction: Action?
    private(set) var lastNotice: String?

    private let vault: CredentialVault
    private let deepgramIntegration: DeepgramNovaStreamingTranscriptionIntegration?

    init(
        vault: CredentialVault,
        deepgramIntegration: DeepgramNovaStreamingTranscriptionIntegration? = nil
    ) {
        self.vault = vault
        self.deepgramIntegration = deepgramIntegration
    }

    // MARK: Status

    func status(for key: CredentialKey) -> CredentialStatus {
        statuses[key] ?? .missing
    }

    /// Explicit refresh of the value-free status map.
    func refresh() async {
        var updated: [CredentialKey: CredentialStatus] = [:]
        for key in CredentialKey.allCases {
            updated[key] = await vault.status(for: key)
        }
        statuses = updated
    }

    /// Providers that currently have a confirmed stored credential.
    var configuredProviders: [CredentialKey] {
        CredentialKey.allCases.filter { statuses[$0] == .configured }
    }

    /// ACC-CREDENTIAL-VAULT-04: a clear, value-free message that blocks only
    /// the affected provider action.
    func blockingMessage(for key: CredentialKey) -> String? {
        CredentialVault.blockingMessage(for: key, status: status(for: key))
    }

    // MARK: Store, replace, delete

    /// Stores or atomically replaces one credential. A failed replacement
    /// leaves the prior Keychain value untouched and reports it honestly.
    @discardableResult
    func save(_ value: String, for key: CredentialKey) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return record(CredentialVaultError.invalidValue(key))
        }

        let hadPriorValue = (try? await vault.hasValue(for: key)) ?? false
        do {
            try await vault.store(key, value: value)
        } catch let error as CredentialVaultError {
            return record(error)
        } catch {
            return record(hadPriorValue ? .replacementFailed(key) : .storeFailed(key))
        }

        statuses[key] = await vault.status(for: key)
        lastFailure = nil
        lastAction = hadPriorValue ? .replaced(key) : .stored(key)
        lastNotice = hadPriorValue
            ? "Replaced the \(key.displayName) API key."
            : "Saved the \(key.displayName) API key."
        return true
    }

    /// Deletes one credential and reports success only after the Keychain
    /// confirms the removal.
    @discardableResult
    func delete(_ key: CredentialKey) async -> Bool {
        do {
            try await vault.delete(key)
        } catch {
            return record(.deletionFailed(key))
        }
        statuses[key] = await vault.status(for: key)
        lastFailure = nil
        lastAction = .deleted(key)
        lastNotice = "Removed the \(key.displayName) API key."
        return true
    }

    // MARK: Connection test

    /// Explicit user action: verifies a provider credential without exposing
    /// any value. Deepgram uses its documented no-audio test connection;
    /// OpenRouter verifies on the first explicit refinement or transcription.
    func testConnection(for key: CredentialKey) async -> CredentialConnectionOutcome {
        let current: CredentialStatus
        if let cached = statuses[key] {
            current = cached
        } else {
            current = await vault.status(for: key)
            statuses[key] = current
        }

        switch current {
        case .missing:
            return .missingCredential
        case .unavailable(let reason):
            return .failed(reason.userFacingMessage)
        case .configured:
            break
        }

        switch key {
        case .deepgramNovaStreamingTranscription:
            guard let deepgramIntegration else {
                return .notAvailable("The Deepgram integration is not available in this build.")
            }
            switch await deepgramIntegration.testConnection() {
            case .succeeded(let requestID):
                return .verified(requestID: requestID)
            case .missingCredential:
                return .missingCredential
            case .failed(let failure):
                return .failed(failure.userFacingMessage)
            }
        case .openRouter:
            return .notAvailable(
                "OpenRouter keys are verified by the first explicit refinement or file transcription."
            )
        case .typesafe:
            return .notAvailable(
                "TypeSafe keys are verified during speech evaluation."
            )
        }
    }

    // MARK: Failure recording

    @discardableResult
    private func record(_ error: CredentialVaultError) -> Bool {
        let category: FailureCategory
        let key: CredentialKey
        switch error {
        case .invalidValue(let affected):
            category = .invalidValue
            key = affected
        case .storeFailed(let affected):
            category = .storeFailed
            key = affected
        case .replacementFailed(let affected):
            category = .replacementFailed
            key = affected
        case .deletionFailed(let affected):
            category = .deletionFailed
            key = affected
        case .unreadable(let affected):
            category = .unreadable
            key = affected
        }
        lastFailure = Failure(category: category, key: key, message: error.userFacingMessage)
        lastNotice = nil
        return false
    }
}
