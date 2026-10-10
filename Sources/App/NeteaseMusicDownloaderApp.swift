import SwiftUI
import AppKit

@main
struct NeteaseMusicDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 780, minHeight: 560)
                // 把 settings 里的 theme / language / liquidGlass 投射到 SwiftUI 环境上。
                // 视图层读 appState.settings.foo 即可，但视觉/语言/材质的应用必须在根上挂。
                // language 用 .id() 强制重建 window 内容（SwiftUI .environment(\.locale) 改了
                // 不会自动重新本地化已渲染的 view tree，要靠 id 触发整树重渲染）。
                .modifier(ThemingModifier(theme: appState.settings.theme))
                .modifier(LocaleModifier(language: appState.settings.language))
                .modifier(MaterialModifier(enabled: appState.settings.liquidGlassEnabled))
                .id("lang-\(appState.settings.language.rawValue)")
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("播放") {
                Button("播放 / 暂停") { appState.player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("下一首") { appState.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("上一首") { appState.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("播放模式：列表循环") { appState.player.setMode(.listLoop) }
                Button("播放模式：单曲循环") { appState.player.setMode(.singleLoop) }
                Button("播放模式：随机") { appState.player.setMode(.shuffle) }
            }
        }

        Settings {
            // macOS 系统级 Settings 窗口（Cmd+,）也用 SettingsView，独立持有 selectedTab
            // 状态（不与主窗口 ContentView 共享——系统设置窗口生命周期独立）。
            SettingsViewStandalone()
                .environmentObject(appState)
        }
    }
}

/// 独立实例给 macOS 系统设置窗口用：与主窗口 ContentView 互不影响 selectedTab。
private struct SettingsViewStandalone: View {
    @State private var selection: SettingsView.SettingsTab = .account
    var body: some View { SettingsView(selection: $selection) }
}

/// AppDelegate 负责 macOS 26 的玻璃背景 / 标题栏样式等需要 NSAppearance 的细节。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Settings 投射到 SwiftUI 环境
//
// SettingsView 改 settings.foo 后，AppState 转发 objectWillChange，
// ContentView / WindowGroup 根视图 body 重算 → modifier 重新求值 →
// 新值进入 SwiftUI 环境，全局生效。

struct ThemingModifier: ViewModifier {
    let theme: AppTheme
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme.colorScheme)
    }
}

struct LocaleModifier: ViewModifier {
    let language: AppLanguage
    func body(content: Content) -> some View {
        if let id = language.localeIdentifier {
            return AnyView(content.environment(\.locale, Locale(identifier: id)))
        } else {
            return AnyView(content)
        }
    }
}

struct MaterialModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        // liquidGlassEnabled 控制 sidebar / detail 的玻璃材质。
        // 关闭时退回普通背景。
        if enabled {
            return AnyView(content)
        } else {
            return AnyView(content.background(.background))
        }
    }
}
