//
//  RoomHubCredentialStore.swift
//  Conduit
//
//  ANVIL-owned credential seam for the Room projection.
//
//  Keep this isolated from AppState/KeychainHelper so upstream Conduit can
//  evolve its application state and ordinary dashboard credentials without
//  forcing ANVIL's Room integration to patch those core files.
//

import Foundation
import Security

protocol RoomHubCredentialBackend {
    func data(account: String) -> Data?
    @discardableResult
    func save(_ data: Data, account: String) -> Bool
    func delete(account: String)
}

struct SystemRoomHubCredentialBackend: RoomHubCredentialBackend {
    private let service = "com.milim.conduit"

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func data(account: String) -> Data? {
        var read = query(account: account)
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return data
    }

    @discardableResult
    func save(_ data: Data, account: String) -> Bool {
        let base = query(account: account)
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

struct RoomHubCredentialStore {
    static let system = RoomHubCredentialStore(backend: SystemRoomHubCredentialBackend())

    private static let accountPrefix = "hermes-conduit.room-hub-credential.v1"
    private let backend: any RoomHubCredentialBackend

    init(backend: any RoomHubCredentialBackend) {
        self.backend = backend
    }

    @discardableResult
    func save(_ credential: RoomHubCredential, dashboardID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else {
            return false
        }
        return backend.save(data, account: account(dashboardID: dashboardID))
    }

    func load(dashboardID: UUID) -> RoomHubCredential? {
        guard let data = backend.data(account: account(dashboardID: dashboardID)) else {
            return nil
        }
        return try? JSONDecoder().decode(RoomHubCredential.self, from: data)
    }

    func clear(dashboardID: UUID) {
        backend.delete(account: account(dashboardID: dashboardID))
    }

    private func account(dashboardID: UUID) -> String {
        "\(Self.accountPrefix).\(dashboardID.uuidString)"
    }
}
