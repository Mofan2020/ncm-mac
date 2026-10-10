import SwiftUI

/// 主窗口：左侧边栏 + 右侧内容区。macOS 26 原生 Sidebar 样式。
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowAccessor())
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(AppTab.allCases, selection: $appState.selectedTab) { tab in
            NavigationLink(value: tab) {
                Label(tab.displayName, systemImage: tab.systemImage)
                    .font(.title3)
            }
        }
        .navigationTitle("网易云音乐")
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
    }

    @ViewBuilder
    private var detail: some View {
        // detail 区需要显式底色：NSWindow 被 WindowAccessor 设为 .clear 透出 sidebar 的玻璃材质，
        // 但 detail 区域默认不画背景，会直接透出桌面色（macOS 26 NavigationSplitView 行为），
        // 导致文字看不清。挂一个 regularMaterial 与 sidebar 视觉一致。
        Group {
            switch appState.selectedTab {
            case .download:
                DownloadView()
            case .play:
                PlayView()
            case .library:
                LibraryView()
            case .localMusic:
                LocalMusicView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { newValue in
                if !newValue { appState.errorMessage = nil }
            }
        )
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}

/// 给主窗口加玻璃材质（macOS 26 Liquid Glass）。NSWindow 通过 NSApp.windows 拿到。
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
