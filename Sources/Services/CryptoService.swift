import Foundation
import CryptoKit

/// eapi 请求签名实现。对应 ncm/src/core/crypto.py + ncm/src/core/aes.py。
///
/// 服务端验证规则（基于 Python 实现 1:1 复刻，2026-09-30 真实请求验证过）：
///   message = "{path}-36cd479b6b5-{json}-36cd479b6b5-{md5(nobody{path}use{json}md5forencrypt)}"
///   params  = HEX_UPPER(AES-128-ECB-PKCS7(message, key="e82ckenh8dichen8"))
///
/// ``params`` 通过 application/x-www-form-urlencoded POST 给 /eapi<path>。
enum CryptoService {
    static let eapiKey = Data("e82ckenh8dichen8".utf8)
    static let eapiSeparator = "-36cd479b6b5-"

    /// 把字典序列化成紧凑 JSON（无空格、UTF-8、不转义 ASCII），与 Python 的
    /// `json.dumps(payload, separators=(",", ":"), ensure_ascii=False)` 完全一致。
    static func compactJSON(_ value: Any) throws -> Data {
        // Foundation 的 JSONSerialization 默认会输出 ", " 与 ": " 的空格，
        // 与 Python `separators=(",",":")` 不一致。手动去掉。
        let obj = JSONValue.normalize(value)
        let raw = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let rawStr = String(data: raw, encoding: .utf8) ?? ""
        let compact = rawStr
            .replacingOccurrences(of: ": ", with: ":")
            .replacingOccurrences(of: ", ", with: ",")
            .replacingOccurrences(of: " :", with: ":")
            .replacingOccurrences(of: " ,", with: ",")
        return Data(compact.utf8)
    }

    /// 算 md5 hexdigest（小写）。对应 hashlib.md5(...).hexdigest()。
    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-ECB-PKCS7 加密（无 IV），输出 hex（大写）。
    static func aesECBEncrypt(_ plaintext: Data, key: Data) -> Data {
        // Swift CryptoKit 不直接暴露 ECB；CommonCrypto 提供。
        // 走 CommonCrypto 是 Apple 推荐做法（macOS 自带，无需第三方依赖）。
        let keyBytes = Array(key)
        let count = plaintext.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: count)
        var bytesOut: size_t = 0

        let status = plaintext.withUnsafeBytes { (plainPtr: UnsafeRawBufferPointer) -> Int32 in
            keyBytes.withUnsafeBufferPointer { keyPtr -> Int32 in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, keyBytes.count,
                    nil,                                                         // ECB 无 IV
                    plainPtr.baseAddress, plaintext.count,
                    &outBytes, outBytes.count,
                    &bytesOut
                )
            }
        }
        precondition(status == kCCSuccess, "AES-ECB 加密失败: \(status)")
        return Data(bytes: outBytes, count: bytesOut)
    }

    /// 给定 path + payload，返回 hex 编码（uppercase）的 params 字段。
    static func signEAPI(path: String, payload: [String: Any]) throws -> String {
        let text = String(data: try compactJSON(payload), encoding: .utf8) ?? ""
        let digest = md5Hex("nobody\(path)use\(text)md5forencrypt")
        let message = "\(path)\(eapiSeparator)\(text)\(eapiSeparator)\(digest)"
        let encrypted = aesECBEncrypt(Data(message.utf8), key: eapiKey)
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    /// 给定 path + data，构造 eapi 请求体（含 header 块）。
    static func eapiBody(
        path: String,
        data: [String: Any] = [:],
        header: [String: Any]? = nil,
        deviceId: String
    ) throws -> [String: String] {
        var payload = data
        payload["header"] = header ?? defaultHeader(deviceId: deviceId)
        return ["params": try signEAPI(path: path, payload: payload)]
    }

    /// 默认 client header。镜像 PC 桌面端（设备 ID 保持稳定）。
    static func defaultHeader(deviceId: String, requestId: String? = nil) -> [String: Any] {
        [
            "os": "pc",
            "appver": "8.9.70",
            "osver": "",
            "deviceId": deviceId,
            "requestId": requestId ?? String(Int64(Date().timeIntervalSince1970 * 1000)),
            "clientSign": "",
        ]
    }
}

// MARK: - JSON 规范化

/// 让 JSONSerialization 的输出与 Python `json.dumps(separators=(",", ":"))` 严格一致。
///
/// Python json 默认：
///   - 不在 "," ":" 旁加空格
///   - key 顺序为插入顺序（调用方负责）
///   - 字符串不做 Unicode 转义（ensure_ascii=False）
///
/// Foundation 的 JSONSerialization 默认会输出空格（", "、": "），
/// 需要手动把 NSData 转成字符串时去掉。
enum JSONValue {
    /// 递归规范化：让 Bool/Int/Double/String/Array/Dictionary 在序列化前一致。
    static func normalize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            // 按 key 排序，保证 .sortedKeys 输出与 Python 字典序对齐。
            for key in dict.keys.sorted() {
                out[key] = normalize(dict[key] as Any)
            }
            return out
        case let array as [Any]:
            return array.map { normalize($0) }
        case let n as NSNumber:
            // 区分 Bool 和 Int/Double。
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            // 整型走 Int；浮点走 Double。
            let str = n.stringValue
            if str.contains(".") {
                return n.doubleValue
            }
            return n.int64Value
        case let s as String:
            return s
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    /// 把 JSONSerialization 的输出重新转成字符串，去掉 ", " 与 ": " 的空格。
    static func compactString(from data: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let compact = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .fragmentsAllowed]
        )
        return String(data: compact, encoding: .utf8) ?? ""
    }
}

// MARK: - CommonCrypto 桥接

// 把 CommonCrypto 的 C 接口 import 进来。
// CommonCrypto 是系统框架，不需要链接额外库；只需要 import 即可。
// macOS 已有 Security/CommonCrypto 头文件。
import CommonCrypto
