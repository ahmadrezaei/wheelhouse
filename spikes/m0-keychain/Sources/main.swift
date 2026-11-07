import Foundation
import Security

// M0 keychain-sync spike (risk R1). Touches exactly ONE keychain item:
//   service "app.wheelhouse.m0-probe", account "probe", synchronizable, in the shared access group.
// Every query below names the service, the account, the access group and synchronizable = true explicitly.
// There is no query that lists or wildcards anything.

let probeService = "app.wheelhouse.m0-probe"
let probeAccount = "probe"
let probeGroup = "JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared"

struct Payload: Codable {
    var token: String
    var writtenAt: String
    var writer: String
}

func baseQuery() -> [CFString: Any] {
    [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: probeService,
        kSecAttrAccount: probeAccount,
        kSecAttrAccessGroup: probeGroup,
        kSecAttrSynchronizable: true,
        kSecUseDataProtectionKeychain: true,
    ]
}

func describe(_ status: OSStatus) -> String {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
    return "OSStatus \(status) (\(message))"
}

func write() -> Int32 {
    let payload = Payload(token: UUID().uuidString, writtenAt: ISO8601DateFormatter().string(from: Date()), writer: "mac")
    guard let data = try? JSONEncoder().encode(payload) else { print("error: encoding"); return 1 }
    var add = baseQuery()
    add[kSecValueData] = data
    add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
    var status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
        status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData: data] as CFDictionary)
    }
    guard status == errSecSuccess else { print("write failed: \(describe(status))"); return 1 }
    print("wrote token=\(payload.token) writtenAt=\(payload.writtenAt) writer=\(payload.writer)")
    return 0
}

func read() -> Int32 {
    var q = baseQuery()
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { print("not found (no probe item visible in group \(probeGroup))"); return 2 }
    guard status == errSecSuccess, let data = result as? Data else { print("read failed: \(describe(status))"); return 1 }
    guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { print("item present but not decodable (\(data.count) bytes)"); return 1 }
    print("read token=\(p.token) writtenAt=\(p.writtenAt) writer=\(p.writer)")
    return 0
}

func delete() -> Int32 {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    if status == errSecItemNotFound { print("nothing to delete"); return 0 }
    guard status == errSecSuccess else { print("delete failed: \(describe(status))"); return 1 }
    print("deleted the probe item")
    return 0
}

let command = CommandLine.arguments.dropFirst().first ?? ""
switch command {
case "write": exit(write())
case "read": exit(read())
case "delete": exit(delete())
default:
    print("usage: m0probe write|read|delete   (touches only service \(probeService), account \(probeAccount))")
    exit(64)
}
