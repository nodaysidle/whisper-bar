import Foundation
import Testing
@testable import Whisperbar

/// TASK-10-CREDENTIAL-VAULT-FEATURE focused checks.
///
/// Covers FEAT-CREDENTIAL-VAULT and contracts CON-CREDENTIAL-VAULT-INTERFACE
/// and CON-CREDENTIAL-VAULT-RECOVERY through the injectable Keychain store.
/// No live Keychain, file, log, or network is touched.
@Suite("CredentialVaultFeature — vault interface and recovery")
@MainActor
struct CredentialVaultFeatureTests {

    typealias FakeKeychainStore = CredentialVaultTests.InMemoryKeychainStore
    typealias FakeSocketFactory = DeepgramNovaStreamingTranscriptionIntegrationTests.FakeSocketFactory
    typealias FakeSocketSession = DeepgramNovaStreamingTranscriptionIntegrationTests.FakeSocketSession

    // MARK: - Helpers

    private func makeVault(store: FakeKeychainStore) -> CredentialVault {
        CredentialVault(store: store, service: "com.whisperbar.app.credentials")
    }

    private func makeFeature(
        store: FakeKeychainStore,
        deepgram: DeepgramNovaStreamingTranscriptionIntegration? = nil
    ) -> (feature: CredentialVaultFeature, store: FakeKeychainStore) {
        let feature = CredentialVaultFeature(vault: makeVault(store: store), deepgramIntegration: deepgram)
        return (feature, store)
    }

    private let secret = "sk-or-v1-SUPERSECRET-0000"

    // MARK: - ACC-CREDENTIAL-VAULT-01 / 03: Keychain only, never in logs or files

    @Test("Saving writes only into the Keychain and no exposed state carries the secret")
    func saveWritesOnlyToKeychain() async {
        let (feature, store) = makeFeature(store: FakeKeychainStore())

        let saved = await feature.save(secret, for: .openRouter)
        #expect(saved)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.value == secret)
        #expect(store.entries.first?.service == "com.whisperbar.app.credentials")

        // Every user-visible string stays value-free.
        #expect(feature.statuses[.openRouter] == .configured)
        let notice = feature.lastNotice ?? ""
        #expect(!notice.contains(secret))
        #expect(!notice.contains("SUPERSECRET"))
        #expect(notice.contains("OpenRouter"))
        #expect(feature.lastFailure == nil)

        let blocking = feature.blockingMessage(for: .openRouter)
        #expect(blocking == nil)
    }

    @Test("An empty or whitespace-only value is rejected before any write")
    func emptyValueRejected() async {
        let (feature, store) = makeFeature(store: FakeKeychainStore())
        #expect(await feature.save("   \n ", for: .deepgramNovaStreamingTranscription) == false)
        #expect(store.storeCallCount == 0)
        #expect(feature.lastFailure?.category == .invalidValue)
        #expect(feature.lastFailure?.key == .deepgramNovaStreamingTranscription)
    }

    // MARK: - ACC-CREDENTIAL-VAULT-02: Atomic updates

    @Test("A failed replacement leaves the previous Keychain value untouched")
    func failedReplacementIsAtomic() async {
        let store = FakeKeychainStore()
        let (feature, _) = makeFeature(store: store)
        #expect(await feature.save("first-valid-key", for: .openRouter))

        store.storeError = .writeFailed(-25300)
        #expect(await feature.save("second-attempt-key", for: .openRouter) == false)

        #expect(feature.lastFailure?.category == .replacementFailed)
        #expect(feature.statuses[.openRouter] == .configured)
        // The prior value is still the one the vault returns.
        let vault = makeVault(store: store)
        #expect(await (try? vault.value(for: .openRouter)) ?? nil == "first-valid-key")

        // Explicit retry succeeds once the store recovers.
        store.storeError = nil
        #expect(await feature.save("second-attempt-key", for: .openRouter))
        #expect(await (try? vault.value(for: .openRouter)) ?? nil == "second-attempt-key")
        #expect(feature.lastFailure == nil)
        #expect(feature.lastAction == .replaced(.openRouter))
    }

    @Test("A first write failure is a store failure and reports nothing saved")
    func firstWriteFailure() async {
        let store = FakeKeychainStore()
        store.storeError = .writeFailed(-25300)
        let (feature, _) = makeFeature(store: store)

        #expect(await feature.save("brand-new-key", for: .deepgramNovaStreamingTranscription) == false)
        #expect(feature.lastFailure?.category == .storeFailed)
        #expect(feature.status(for: .deepgramNovaStreamingTranscription) == .missing)
        let message = feature.lastFailure?.message ?? ""
        #expect(!message.contains("brand-new-key"))
    }

    // MARK: - Deletion confirmation

    @Test("Deletion is reported only after the Keychain confirms it")
    func deletionConfirmation() async {
        let store = FakeKeychainStore()
        let (feature, _) = makeFeature(store: store)
        _ = await feature.save(secret, for: .openRouter)

        store.deleteError = .deleteFailed(-25300)
        #expect(await feature.delete(.openRouter) == false)
        #expect(feature.lastFailure?.category == .deletionFailed)
        #expect(feature.statuses[.openRouter] == .configured)

        store.deleteError = nil
        #expect(await feature.delete(.openRouter))
        #expect(feature.statuses[.openRouter] == .missing)
        #expect(feature.lastAction == .deleted(.openRouter))
        #expect(store.entries.isEmpty)
    }

    // MARK: - ACC-CREDENTIAL-VAULT-04: Missing credentials block provider use

    @Test("A missing credential blocks its provider with a clear, value-free message")
    func missingCredentialBlocksProvider() async {
        let (feature, _) = makeFeature(store: FakeKeychainStore())
        await feature.refresh()

        let deepgramMessage = feature.blockingMessage(for: .deepgramNovaStreamingTranscription) ?? ""
        #expect(deepgramMessage.contains("Deepgram"))
        #expect(deepgramMessage.contains("Settings"))

        let openRouterMessage = feature.blockingMessage(for: .openRouter) ?? ""
        #expect(openRouterMessage.contains("OpenRouter"))

        #expect(feature.configuredProviders.isEmpty)
    }

    @Test("An unreadable Keychain marks the provider unavailable instead of pretending")
    func unreadableVaultIsHonest() async {
        let store = FakeKeychainStore()
        store.readError = .readFailed(-25308)
        let (feature, _) = makeFeature(store: store)
        await feature.refresh()

        guard case .unavailable = feature.statuses[.openRouter] else {
            Issue.record("expected an unavailable status, got \(String(describing: feature.statuses[.openRouter]))")
            return
        }
        let message = feature.blockingMessage(for: .openRouter) ?? ""
        #expect(message.contains("OpenRouter"))
        #expect(feature.configuredProviders.isEmpty)
    }

    @Test("Only configured providers are reported as available")
    func configuredProvidersReported() async {
        let (feature, _) = makeFeature(store: FakeKeychainStore())
        _ = await feature.save("dg-key", for: .deepgramNovaStreamingTranscription)
        await feature.refresh()
        #expect(feature.configuredProviders == [.deepgramNovaStreamingTranscription])
    }

    // MARK: - Recovery paths

    @Test("Recovery is an explicit retry that preserves the last valid state")
    func explicitRetryAfterFailure() async {
        let store = FakeKeychainStore()
        let (feature, _) = makeFeature(store: store)
        _ = await feature.save("stable-key", for: .deepgramNovaStreamingTranscription)

        store.storeError = .writeFailed(-25300)
        #expect(await feature.save("replacement-fails", for: .deepgramNovaStreamingTranscription) == false)
        #expect(feature.statuses[.deepgramNovaStreamingTranscription] == .configured)
        #expect(feature.lastFailure != nil)

        store.storeError = nil
        #expect(await feature.save("replacement-works", for: .deepgramNovaStreamingTranscription))
        #expect(feature.lastFailure == nil)
    }

    // MARK: - Test connection integration

    @Test("Deepgram connection tests report verified, missing, and failure states")
    func deepgramConnectionTest() async {
        let socketFactory = FakeSocketFactory()
        socketFactory.session = FakeSocketSession(upgradeRequestID: "dg-verify-1")
        socketFactory.session.enqueue(text: #"{"type":"Metadata","request_id":"dg-verify-1","duration":0.0,"channels":0}"#)

        let store = FakeKeychainStore()
        let vault = makeVault(store: store)
        let deepgram = DeepgramNovaStreamingTranscriptionIntegration(
            credentialVault: vault,
            socketFactory: socketFactory
        )
        let feature = CredentialVaultFeature(vault: vault, deepgramIntegration: deepgram)

        // Missing credential: no socket may open.
        #expect(await feature.testConnection(for: .deepgramNovaStreamingTranscription) == .missingCredential)
        #expect(socketFactory.connectCount == 0)

        _ = await feature.save("dg-key", for: .deepgramNovaStreamingTranscription)
        #expect(await feature.testConnection(for: .deepgramNovaStreamingTranscription) == .verified(requestID: "dg-verify-1"))
        #expect(socketFactory.session.sentBinaries.isEmpty)

        // OpenRouter has no free connection test; it verifies on first explicit use.
        _ = await feature.save(secret, for: .openRouter)
        guard case .notAvailable = await feature.testConnection(for: .openRouter) else {
            Issue.record("expected notAvailable for OpenRouter")
            return
        }
    }
}
