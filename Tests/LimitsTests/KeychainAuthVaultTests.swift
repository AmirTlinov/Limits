import Foundation
import Testing
@testable import LimitsCore

@Test func keychainVaultCachesSuccessfulReadsForSession() throws {
    let store = CountingKeychainAuthStore(readData: Data("secret".utf8))
    let vault = KeychainAuthVault(store: store)

    let first = try vault.read(account: "account.one")
    let second = try vault.read(account: "account.one")

    #expect(first == Data("secret".utf8))
    #expect(second == Data("secret".utf8))
    #expect(store.readCount == 1)
}

@Test func keychainVaultSaveStillWritesThroughWhenDataWasCached() throws {
    let store = CountingKeychainAuthStore(readData: Data("secret".utf8))
    let vault = KeychainAuthVault(store: store)

    _ = try vault.read(account: "account.one")
    try vault.save(Data("secret".utf8), account: "account.one", label: "Account One")

    #expect(store.readCount == 1)
    #expect(store.saveCount == 1)
}

@Test func keychainVaultDeleteClearsSessionCache() throws {
    let store = CountingKeychainAuthStore(readData: Data("secret".utf8))
    let vault = KeychainAuthVault(store: store)

    _ = try vault.read(account: "account.one")
    try vault.delete(account: "account.one")
    _ = try vault.read(account: "account.one")

    #expect(store.deleteCount == 1)
    #expect(store.readCount == 2)
}

@Test func keychainVaultSerializesConcurrentStoreAccess() {
    let store = ConcurrentAccessObservingKeychainStore()
    let vault = KeychainAuthVault(store: store)

    DispatchQueue.concurrentPerform(iterations: 32) { index in
        try! vault.save(
            Data("secret-\(index)".utf8),
            account: "account.\(index)",
            label: "Account \(index)"
        )
    }

    #expect(store.maximumConcurrentCalls == 1)
}

private final class CountingKeychainAuthStore: KeychainAuthDataStore {
    private let readData: Data
    private(set) var readCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(readData: Data) {
        self.readData = readData
    }

    func save(_ data: Data, account: String, label: String) throws {
        saveCount += 1
    }

    func read(account: String) throws -> Data {
        readCount += 1
        return readData
    }

    func delete(account: String) throws {
        deleteCount += 1
    }
}

private final class ConcurrentAccessObservingKeychainStore: KeychainAuthDataStore {
    private let lock = NSLock()
    private var activeCalls = 0
    private var observedMaximumConcurrentCalls = 0

    var maximumConcurrentCalls: Int {
        lock.withLock { observedMaximumConcurrentCalls }
    }

    func save(_ data: Data, account: String, label: String) throws {
        beginCall()
        Thread.sleep(forTimeInterval: 0.002)
        endCall()
    }

    func read(account: String) throws -> Data {
        beginCall()
        defer { endCall() }
        return Data()
    }

    func delete(account: String) throws {
        beginCall()
        endCall()
    }

    private func beginCall() {
        lock.withLock {
            activeCalls += 1
            observedMaximumConcurrentCalls = max(observedMaximumConcurrentCalls, activeCalls)
        }
    }

    private func endCall() {
        lock.withLock {
            activeCalls -= 1
        }
    }
}
