import Foundation
import SwiftUI
import Combine

/// 网易云账号服务。对应 ncm/src/auth/login.py。
///
/// 提供三种登录入口：
///   - QR 登录（推荐）：拉 unikey → 客户端展示二维码 → 轮询扫码状态
///   - 手机验证码登录
///   - 导入浏览器 Cookie（针对 web 登录的特殊场景）
///
/// 登录成功后会从响应里解析出 ``MUSIC_U=`` 开头的 cookie，写入 ``NeteaseAPI.cookie``
/// 并保存到 Keychain（避免每次启动都重新登录）。
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var account: Account?
    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var qrState: QRState = .idle
    @Published private(set) var qrImageURL: URL?

    var onCookieChanged: ((String?) -> Void)?
    var onAccountChanged: ((Account?) -> Void)?

    private let api: NeteaseAPI
    private let keychain = KeychainStore(service: "com.mofan2020.neteasemusicdownloader.cookie")
    private var pollTask: Task<Void, Never>?
    private var qrKey: String?

    init(api: NeteaseAPI) {
        self.api = api
        if let savedCookie = keychain.read(key: "session") {
            api.setCookie(savedCookie)
            onCookieChanged?(savedCookie)
            Task { await self.bootstrapFromCookie() }
        }
    }

    // MARK: - QR login

    func startQRLogin() async {
        qrState = .waitingForKey
        do {
            let key = try await api.qrKey()
            self.qrKey = key
            self.qrImageURL = URL(string: "https://music.163.com/login?codekey=\(key)")
            self.qrState = .waitingForScan
            startPolling()
        } catch {
            qrState = .failed(message: error.localizedDescription)
        }
    }

    func cancelQRLogin() {
        pollTask?.cancel()
        pollTask = nil
        qrKey = nil
        qrState = .idle
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await self.pollQR()
                if self.qrState.isTerminal { return }
            }
        }
    }

    private func pollQR() async {
        guard let key = qrKey else { return }
        do {
            let (code, cookie) = try await api.qrPoll(unikey: key)
            switch code {
            case 801:
                qrState = .waitingForScan
            case 802:
                qrState = .waitingForConfirm
            case 803:
                qrState = .success
                if let cookie {
                    completeLogin(cookie: cookie)
                } else {
                    qrState = .failed(message: "登录成功但未拿到 cookie")
                }
            case 800:
                qrState = .expired
            default:
                qrState = .failed(message: "未知状态码：\(code)")
            }
        } catch {
            qrState = .failed(message: error.localizedDescription)
        }
    }

    private func completeLogin(cookie: String) {
        api.setCookie(cookie)
        keychain.write(key: "session", value: cookie)
        onCookieChanged?(cookie)
        Task { await refreshAccount() }
    }

    private func bootstrapFromCookie() async {
        await refreshAccount()
    }

    // MARK: - Phone login

    func sendCaptcha(phone: String, countryCode: String = "86") async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "\(NeteaseAPI.legacyHost)/api/sms/captcha/sent")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "phone=\(phone.urlEncoded)&ctcode=\(countryCode.urlEncoded)"
            request.httpBody = Data(body.utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return (json["code"] as? Int) == 200
        } catch {
            return false
        }
    }

    func loginWithPhone(phone: String, captcha: String, countryCode: String = "86") async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "\(NeteaseAPI.legacyHost)/api/w/login/cellphone")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "phone=\(phone.urlEncoded)&password=\(captcha.urlEncoded)&countrycode=\(countryCode.urlEncoded)"
            request.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            guard (json["code"] as? Int) == 200, let cookie = json["cookie"] as? String else {
                return false
            }
            completeLogin(cookie: cookie)
            return true
        } catch {
            return false
        }
    }

    func loginWithCookieString(_ raw: String) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized: String
        if trimmed.contains("MUSIC_U=") {
            normalized = trimmed
        } else {
            normalized = "MUSIC_U=\(trimmed)"
        }
        completeLogin(cookie: normalized)
        return true
    }

    // MARK: - Account refresh

    func refreshAccount() async {
        do {
            if let account = try await api.fetchAccount() {
                self.account = account
                self.isLoggedIn = true
                onAccountChanged?(account)
            } else {
                clearSession()
            }
        } catch {
            clearSession()
        }
    }

    func logout() async {
        if let cookie = api.cookie {
            var request = URLRequest(url: URL(string: "\(NeteaseAPI.legacyHost)/api/logout")!)
            request.httpMethod = "POST"
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = Data("".utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
        keychain.delete(key: "session")
        api.setCookie(nil)
        clearSession()
        onCookieChanged?(nil)
    }

    private func clearSession() {
        self.account = nil
        self.isLoggedIn = false
        onAccountChanged?(nil)
    }

    // MARK: - QR State

    enum QRState: Equatable {
        case idle
        case waitingForKey
        case waitingForScan
        case waitingForConfirm
        case success
        case expired
        case failed(message: String)

        var isTerminal: Bool {
            switch self {
            case .success, .expired, .failed: return true
            default: return false
            }
        }

        var displayName: String {
            switch self {
            case .idle: return "未开始"
            case .waitingForKey: return "准备中…"
            case .waitingForScan: return "请使用网易云音乐 APP 扫码"
            case .waitingForConfirm: return "已扫码，请在手机上点确认"
            case .success: return "登录成功"
            case .expired: return "二维码已过期，请重试"
            case .failed(let msg): return "失败：\(msg)"
            }
        }
    }
}
