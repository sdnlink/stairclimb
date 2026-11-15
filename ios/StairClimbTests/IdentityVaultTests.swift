import XCTest
import Security
@testable import StairClimb

final class MemorySecureStore: SecureDataStoring {
    var data: Data?
    var failReads = false
    var failWrites = false
    enum Failure: Error { case unavailable }
    func read() throws -> Data? {
        if failReads { throw Failure.unavailable }
        return data
    }
    func write(_ data: Data) throws {
        if failWrites { throw Failure.unavailable }
        self.data = data
    }
}

final class IdentityVaultTests: XCTestCase {
    func testIdentitySurvivesVaultRecreationAndNicknameChange() throws {
        let store = MemorySecureStore()
        let identity = LocalIdentity(installationID: UUID(), nickname: "小楼")
        try IdentityVault(store: store).save(identity)
        var reloaded = try XCTUnwrap(IdentityVault(store: store).load())
        XCTAssertEqual(reloaded, identity)
        reloaded.nickname = "新名字"
        try IdentityVault(store: store).save(reloaded)
        XCTAssertEqual(try IdentityVault(store: store).load()?.installationID, identity.installationID)
        XCTAssertEqual(try IdentityVault(store: store).load()?.nickname, "新名字")
    }

    func testAbsentCorruptAndInaccessibleItemsAreDifferent() throws {
        let store = MemorySecureStore()
        let vault = IdentityVault(store: store)
        XCTAssertNil(try vault.load())
        store.data = Data("corrupt".utf8)
        XCTAssertThrowsError(try vault.load())
        store.failReads = true
        XCTAssertThrowsError(try vault.load())
        XCTAssertEqual(store.data, Data("corrupt".utf8))
    }

    func testFailedWriteDoesNotErasePreviousIdentity() throws {
        let store = MemorySecureStore()
        let vault = IdentityVault(store: store)
        let identity = LocalIdentity(installationID: UUID(), nickname: "楼友")
        try vault.save(identity)
        store.failWrites = true
        XCTAssertThrowsError(try vault.save(LocalIdentity(installationID: UUID(), nickname: "另一个")))
        XCTAssertEqual(try vault.load(), identity)
    }

    func testNicknameMatchesServerScalarRules() throws {
        XCTAssertEqual(try NicknameRules.validate("  小楼 🏃  "), "小楼 🏃")
        XCTAssertNoThrow(try NicknameRules.validate(String(repeating: "楼", count: 24)))
        for value in ["", " \n ", String(repeating: "楼", count: 25), "楼\n友", "楼\t友",
                      "楼\u{200D}友", "楼\u{00A0}友", "楼\u{E000}友"] {
            XCTAssertThrowsError(try NicknameRules.validate(value))
        }
    }

    func testActualKeychainInsertUpdateAndRead() throws {
        // Uses a random service and cleans only this test item; never touches app credentials.
        let service = "cn.stairclimb.tests.\(UUID().uuidString)"
        defer {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
        }
        let store = KeychainStore(service: service, account: "test")
        XCTAssertNil(try store.read())
        try store.write(Data("first".utf8))
        XCTAssertEqual(try store.read(), Data("first".utf8))
        try store.write(Data("updated".utf8))
        XCTAssertEqual(try store.read(), Data("updated".utf8))
    }
}
