import Foundation
import CryptoKit

/// eapi 请求签名实现。对应 ncm/src/core/crypto.py + ncm/src/core/aes.py。
///
/// 服务端验证规则（基于 Python 实现 1:1 复刻）：
///   message = "{path}-36cd479b6b5-{json}-36cd479b6b5-{md5(nobody{path}use{json}md5forencrypt)}"
///   params  = HEX_UPPER(AES-128-ECB-PKCS7(message, key="e82ckenh8dichen8"))
///
/// ``params`` 通过 application/x-www-form-urlencoded POST 给 /eapi<path>。
///
/// 实现说明：
/// - 网易云服务端按 JSON 字符串的字节做 md5，**字段顺序必须保留**（Python json.dumps 默认行为）
/// - Swift 的 `[String: Any]` 是无序哈希表，因此本模块强制使用 ``OrderedDict`` = `[(String, Any)]`
/// - JSON 编码使用 ``JEncoder`` 手写实现，与 Python `json.dumps(separators=(",", ":"), ensure_ascii=False)` 严格一致
enum CryptoService {
    static let eapiKey = Data("e82ckenh8dichen8".utf8)
    static let eapiSeparator = "-36cd479b6b5-"

    /// 算 md5 hexdigest（小写）。对应 hashlib.md5(...).hexdigest()。
    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-ECB-PKCS7 加密（无 IV）。
    static func aesECBEncrypt(_ plaintext: Data, key: Data) -> Data {
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

    /// 把 ``OrderedDict`` 序列化成紧凑 JSON 字节流。
    /// 等价于 Python: json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    /// （dict 按调用方构造时的插入顺序写出；字符串不做 Unicode 转义）
    static func compactJSON(_ payload: OrderedDict) -> Data {
        Data(JEncoder.encode(payload).utf8)
    }

    /// 给定 path + payload，返回 hex 编码（uppercase）的 params 字段。
    static func signEAPI(path: String, payload: OrderedDict) throws -> String {
        let text = JEncoder.encode(payload)
        let digest = md5Hex("nobody\(path)use\(text)md5forencrypt")
        let message = "\(path)\(eapiSeparator)\(text)\(eapiSeparator)\(digest)"
        let encrypted = aesECBEncrypt(Data(message.utf8), key: eapiKey)
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    /// 给定 path + data，构造 eapi 请求体（含 header 块）。
    ///
    /// - Parameter data: 业务字段。``header`` 字段由本方法追加在末尾（与 Python ``eapi_body`` 行为一致）。
    /// - Parameter header: 可选覆盖默认 header。
    static func eapiBody(
        path: String,
        data: OrderedDict = [],
        header: OrderedDict? = nil,
        deviceId: String
    ) throws -> [String: String] {
        var payload = data
        payload.append(("header", AnyValue(header ?? defaultHeader(deviceId: deviceId))))
        return ["params": try signEAPI(path: path, payload: payload)]
    }

    /// 默认 client header。镜像 PC 桌面端（设备 ID 保持稳定）。
    static func defaultHeader(deviceId: String, requestId: String? = nil) -> OrderedDict {
        [
            ("os", .string("pc")),
            ("appver", .string("8.9.70")),
            ("osver", .string("")),
            ("deviceId", .string(deviceId)),
            ("requestId", .string(requestId ?? String(Int64(Date().timeIntervalSince1970 * 1000)))),
            ("clientSign", .string("")),
        ]
    }
}

// MARK: - 有序 Dict

/// 有序字典（key 顺序由构造时的 append 顺序决定）。
///
/// Swift 的 `[String: Any]` 是无序哈希表，但 eapi 签名要求 JSON 字段顺序与服务端解析后还原的
/// 一致（Python `json.dumps` 默认保留插入顺序）。``OrderedDict`` 内部用数组存储键值对，
/// 既支持 JSON 序列化，也能在 SwiftUI binding 场景下与 `[String: Any]` 通过 ``OrderedDict.init(_:)`` 互换。
typealias OrderedDict = [(String, AnyValue)]

/// JSON 字面量类型。和 Python `json.dumps` 行为对齐的紧凑表示。
indirect enum AnyValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyValue])
    case ordered(OrderedDict)  // 有序 dict

    // MARK: - Convenience constructors

    static func int(_ v: Int) -> AnyValue { .int(Int64(v)) }

    /// 从 `[String: Any]` 构造。**注意**：Swift 字典本身无序，构造时会按当前哈希桶顺序写入。
    /// 仅在你确认 dict 顺序无关紧要时使用（多数 eapi 业务字段都是扁平且不影响签名的）。
    init(_ d: [String: Any]) {
        self = .ordered(d.map { ($0.key, AnyValue($0.value)) })
    }

    init(_ v: Any?) {
        switch v {
        case nil, is NSNull:
            self = .null
        case let b as Bool:
            self = .bool(b)
        case let i as Int:
            self = .int(Int64(i))
        case let i as Int64:
            self = .int(i)
        case let d as Double:
            self = .double(d)
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { AnyValue($0) })
        case let od as OrderedDict:
            self = .ordered(od)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                let s = n.stringValue
                if s.contains(".") {
                    self = .double(n.doubleValue)
                } else {
                    self = .int(n.int64Value)
                }
            }
        default:
            self = .string(String(describing: v!))
        }
    }
}

// MARK: - 紧凑 JSON 编码器

/// 与 Python `json.dumps(value, separators=(",", ":"), ensure_ascii=False)` 字节对齐的紧凑 JSON 编码器。
enum JEncoder {
    static func encode(_ payload: OrderedDict) -> String {
        var out = ""
        out += "{"
        for (i, (k, v)) in payload.enumerated() {
            if i > 0 { out += "," }
            out += encodeString(k)
            out += ":"
            write(v, into: &out)
        }
        out += "}"
        return out
    }

    static func encode(_ value: AnyValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: AnyValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if d.isNaN || d.isInfinite {
                out += "null"
            } else if d == d.rounded() && abs(d) < 1e15 {
                // 整数值的 Double 走整数输出（与 Python json 默认行为对齐）
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .string(let s):
            out += encodeString(s)
        case .array(let a):
            out += "["
            for (i, e) in a.enumerated() {
                if i > 0 { out += "," }
                write(e, into: &out)
            }
            out += "]"
        case .ordered(let pairs):
            out += "{"
            for (i, (k, v)) in pairs.enumerated() {
                if i > 0 { out += "," }
                out += encodeString(k)
                out += ":"
                write(v, into: &out)
            }
            out += "}"
        }
    }

    /// Python `json.dumps(ensure_ascii=False)` 风格的字符串编码：原样写 UTF-8，仅对控制字符与
    /// `\"` `\\` 做转义。emoji / CJK 不会被转义成 `\uXXXX`。
    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out += String(c)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - CommonCrypto 桥接

// CommonCrypto 是系统框架，不需要链接额外库；只需要 import 即可。
// macOS 已有 Security/CommonCrypto 头文件，Xcode 构建自动可见。
import CommonCrypto
