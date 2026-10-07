import SwiftUI

/// 占位：设置页。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("通用") {
                Toggle("启动时检查更新", isOn: .constant(true))
            }
        }
        .padding()
    }
}
