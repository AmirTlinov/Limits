import Foundation
import Testing
@testable import Limits

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
