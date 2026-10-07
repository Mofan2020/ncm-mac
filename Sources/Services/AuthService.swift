import Foundation

/// 占位。
final class AuthService {
    var onCookieChanged: ((String?) -> Void)?
    var onAccountChanged: ((Account?) -> Void)?
    init(api: NeteaseAPI) {}
}
