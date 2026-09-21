import Foundation
import Testing
@testable import Whisperbar

/// TASK-02-CREDENTIAL-VAULT focused checks.
///
/// Covers CON-DATA-API-CREDENTIAL, CON-CREDENTIAL-DEEPGRAM-NOVA-STREAMING-TRANSCRIPTION,
/// CON-CREDENTIAL-OPENROUTER using an injectable in-memory Keychain seam.
/// No live Keychain item is ever touched by these tests.
@Suite("CredentialVault — Keychain-only credential contract")
struct CredentialVaultTests {

    // MARK: - Test seam

    final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
        struct Entry: Equatable {
            let service: String
            let account: String
            let value: String
        }

        private let lock = NSLock()
        private var storage: [Entry] = []

        var storeError: KeychainStoreError?
        var readError: KeychainStoreError?
        var deleteError: KeychainStoreError?
        private(set) var readCallCount = 0
        private(set) var storeCallCount = 0
        private(set) var deleteCallCount = 0

        func read(account: String, service: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            readCallCount += 1
            if let error = readError { throw error }
            return storage.first { $0.account == account && $0.service == service }?.value
        }

        func store(value: String, account: String, service: String) throws {
            lock.lock(); defer { lock.unlock() }
            storeCallCount += 1
            if let error = storeError { throw error }
            storage.removeAll { $0.account == account && $0.service == service }
            storage.append(Entry(service: service, account: account, value: value))
        }

        func delete(account: String, service: String) throws {
            lock.lock(); defer { lock.unlock() }
            deleteCallCount += 1
            if let error = deleteError { throw error }
            storage.removeAll { $0.account == account && $0.service == service }
        }

        var entries: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private static func makeVault() -> (CredentialVault, InMemoryKeychainStore) {
        let store = InMemoryKeychainStore()
        return (CredentialVault(store: store), store)
    }

    // MARK: - Round trip

    @Test("Stores and retrieves a credential value through the injected store")
    func roundTrip() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.deepgramNovaStreamingTranscription, value: "dg-test-value-1234")
        let value = try await vault.value(for: .deepgramNovaStreamingTranscription)
        #expect(value == "dg-test-value-1234")
        #expect(store.storeCallCount == 1)
        #expect(store.readCallCount == 1)
    }

    @Test("Reads the exact locked service and account names")
    func exactServiceAndAccount() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.openRouter, value: "or-test-value")
        try await vault.store(.deepgramNovaStreamingTranscription, value: "dg-test-value")

        let openRouter = try #require(store.entries.first { $0.account == AppIdentity.openRouterKeychainAccount })
        #expect(openRouter.service == "com.whisperbar.app.credentials")

        let deepgram = try #require(store.entries.first { $0.account == AppIdentity.deepgramKeychainAccount })
        #expect(deepgram.service == "com.whisperbar.app.credentials")
        #expect(store.entries.count == 2)
    }

    @Test("Missing credential reads as nil rather than an error")
    func missingReadsNil() async throws {
        let (vault, _) = Self.makeVault()
        let value = try await vault.value(for: .openRouter)
        #expect(value == nil)
        let has = try await vault.hasValue(for: .openRouter)
        #expect(has == false)
    }

    // MARK: - Atomic replacement

    @Test("Credential updates replace atomically")
    func replacementIsAtomic() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.openRouter, value: "first-value")
        try await vault.store(.openRouter, value: "second-value")
        #expect(try await vault.value(for: .openRouter) == "second-value")
        #expect(store.entries.count == 1)
    }

    @Test("A failed replacement preserves the prior Keychain value")
    func failedReplacementPreservesPriorValue() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.openRouter, value: "prior-value")
        store.storeError = .writeFailed(-25300)

        await #expect(throws: CredentialVaultError.self) {
            try await vault.store(.openRouter, value: "replacement-value")
        }
        #expect(try await vault.value(for: .openRouter) == "prior-value")
    }

    // MARK: - Deletion

    @Test("Deletion removes the item and is idempotent when already absent")
    func deletion() async throws {
        let (vault, _) = Self.makeVault()
        try await vault.store(.deepgramNovaStreamingTranscription, value: "value")
        try await vault.delete(.deepgramNovaStreamingTranscription)
        #expect(try await vault.value(for: .deepgramNovaStreamingTranscription) == nil)
        // Second deletion of an absent item must not throw.
        try await vault.delete(.deepgramNovaStreamingTranscription)
    }

    @Test("Deletion failure is reported and blocks nothing else")
    func deletionFailureReported() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.openRouter, value: "value")
        store.deleteError = .deleteFailed(-25291)
        await #expect(throws: CredentialVaultError.self) {
            try await vault.delete(.openRouter)
        }
        // The credential remains readable: nothing was half-deleted.
        #expect(try await vault.value(for: .openRouter) == "value")
    }

    // MARK: - Validation and privacy-safe failure states

    @Test("Empty or whitespace-only input is rejected without writing anything")
    func emptyValueRejected() async throws {
        let (vault, store) = Self.makeVault()
        await #expect(throws: CredentialVaultError.self) {
            try await vault.store(.openRouter, value: "")
        }
        await #expect(throws: CredentialVaultError.self) {
            try await vault.store(.openRouter, value: "   \n")
        }
        #expect(store.storeCallCount == 0)
        #expect(store.entries.isEmpty)
    }

    @Test("Credentials with surrounding whitespace and newlines are trimmed on storage")
    func surroundingWhitespaceTrimmed() async throws {
        let (vault, store) = Self.makeVault()
        try await vault.store(.openRouter, value: "  \n sk-test-key-trimmed \t ")
        let retrieved = try await vault.value(for: .openRouter)
        #expect(retrieved == "sk-test-key-trimmed")
        #expect(store.entries.first?.value == "sk-test-key-trimmed")
    }

    @Test("Status maps to missing, configured, or unavailable without exposing values")
    func statusMapping() async throws {
        let (vault, _) = Self.makeVault()
        #expect(await vault.status(for: .openRouter) == .missing)
        try await vault.store(.openRouter, value: "configured-value")
        #expect(await vault.status(for: .openRouter) == .configured)
        #expect(await vault.status(for: .deepgramNovaStreamingTranscription) == .missing)

        // Unreadable Keychain maps to .unavailable, never to a crash or leak.
        let failingReadStore = InMemoryKeychainStore()
        failingReadStore.readError = .readFailed(-25308)
        let failingReadVault = CredentialVault(store: failingReadStore)
        #expect(await failingReadVault.status(for: .openRouter) == .unavailable(reason: .unreadable(.openRouter)))

        // A failed first write surfaces a provider-scoped store failure.
        let failingWriteStore = InMemoryKeychainStore()
        failingWriteStore.storeError = .writeFailed(-25300)
        let failingWriteVault = CredentialVault(store: failingWriteStore)
        await #expect(throws: CredentialVaultError.storeFailed(.openRouter)) {
            try await failingWriteVault.store(.openRouter, value: "x")
        }
    }

    @Test("Errors never embed the secret value")
    func errorsDoNotLeakValues() async throws {
        let marker = "sk-TEST-SECRET-MARKER-0001"
        let store = InMemoryKeychainStore()
        store.storeError = .writeFailed(-25300)
        let vault = CredentialVault(store: store)
        do {
            try await vault.store(.openRouter, value: marker)
            Issue.record("expected failure")
        } catch {
            #expect(!"\(error)".contains(marker))
            #expect(!"\(error)".contains("TEST-SECRET"))
        }
        // Success does not log either: the value is only ever inside the store.
        #expect(store.entries.isEmpty)
    }

    @Test("Missing credentials block provider use with a clear, value-free message")
    func missingCredentialBlocksProvider() async throws {
        let (vault, _) = Self.makeVault()
        let message = CredentialVault.blockingMessage(for: .deepgramNovaStreamingTranscription, status: .missing)
        #expect(message != nil)
        #expect(message?.contains("Deepgram") == true)
        #expect(try await vault.value(for: .deepgramNovaStreamingTranscription) == nil)
        #expect(CredentialVault.blockingMessage(for: .openRouter, status: .configured) == nil)
    }
}
