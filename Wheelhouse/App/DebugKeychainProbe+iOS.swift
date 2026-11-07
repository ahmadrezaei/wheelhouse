#if DEBUG
import Foundation
import Security
import UIKit

/// DEBUG-only hook for the Mac keychain-sync spike (design/mac, risk R1).
///
/// Launch with `-WHKeychainProbe write`, `read` or `delete`. It operates on exactly ONE keychain item:
/// service `app.wheelhouse.m0-probe`, account `probe`, synchronizable, in the shared access group. Every query names the
/// service, account, group and synchronizable flag explicitly; nothing is listed or wildcarded, so no cluster
/// credential, mirror or token item is ever touched. The whole file is compiled out of Release builds.
enum DebugKeychainProbe {
    private static let service = "app.wheelhouse.m0-probe"
    private static let account = "probe"
    private static let group = "JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared"

    private struct Payload: Codable { var token: String; var writtenAt: String; var writer: String }

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-WHKeychainProbe"), i + 1 < args.count else { return }
        let message: String
        switch args[i + 1] {
        case "write": message = write()
        case "read": message = read()
        case "delete": message = delete()
        default: message = "Unknown command '\(args[i + 1])'. Use write, read or delete."
        }
        NSLog("WHKeychainProbe: %@", message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            present(message)
        }
    }

    private static func query() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrAccessGroup: group, kSecAttrSynchronizable: true, kSecUseDataProtectionKeychain: true,
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        "OSStatus \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "unknown"))"
    }

    private static func write() -> String {
        let payload = Payload(token: UUID().uuidString, writtenAt: ISO8601DateFormatter().string(from: Date()), writer: "ios")
        guard let data = try? JSONEncoder().encode(payload) else { return "write failed: encoding" }
        var add = query()
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        guard status == errSecSuccess else { return "write failed: \(describe(status))" }
        return "wrote token=\(payload.token) writtenAt=\(payload.writtenAt) writer=\(payload.writer)"
    }

    private static func read() -> String {
        var q = query()
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "not found (no probe item visible in the shared group)" }
        guard status == errSecSuccess, let data = result as? Data else { return "read failed: \(describe(status))" }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return "item present but not decodable (\(data.count) bytes)" }
        return "read token=\(p.token) writtenAt=\(p.writtenAt) writer=\(p.writer)"
    }

    private static func delete() -> String {
        let status = SecItemDelete(query() as CFDictionary)
        if status == errSecItemNotFound { return "nothing to delete" }
        return status == errSecSuccess ? "deleted the probe item" : "delete failed: \(describe(status))"
    }

    @MainActor private static func present(_ message: String) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: "Keychain probe", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }
}
#endif
