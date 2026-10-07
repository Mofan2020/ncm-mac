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
            SettingsView()
                .environmentObject(appState)
        }
    }
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
