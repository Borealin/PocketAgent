import Foundation

/// RP records used by the local developer tunnel, not USB/Lockdown records.
nonisolated enum PairingImport {
    static let maximumBytes = 1_048_576

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = value as? [String: Any] else { throw ImportError.notPlist }
        if plist["HostCertificate"] != nil || plist["HostID"] != nil {
            throw ImportError.lockdownRecord
        }
        guard let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.notRPRecord
        }
        if let irk = plist["alt_irk"], (irk as? Data)?.count != 16 { throw ImportError.notRPRecord }
    }

    enum ImportError: LocalizedError, Equatable {
        case tooLarge, notPlist, lockdownRecord, notRPRecord
        var errorDescription: String? {
            switch self {
            case .tooLarge: "配对文件超过 1 MB，请选择 rp_pairing_file.plist。"
            case .notPlist: "这个文件不是配对属性列表，请选择 rp_pairing_file.plist。"
            case .lockdownRecord: "这是 SideStore/USB 的 Lockdown 配对文件。手机操作需要本机的 RP 配对文件，获取方法见本页说明。"
            case .notRPRecord: "缺少有效的 RP 配对信息，请重新为这台 iPhone 生成 rp_pairing_file.plist。"
            }
        }
    }
}
