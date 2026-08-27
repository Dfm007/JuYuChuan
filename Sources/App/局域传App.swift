import SwiftUI

@main
struct 局域传App: App {
    init() {
        triggerNetworkPermission()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }

    private func triggerNetworkPermission() {
        guard let url = URL(string: "https://baidu.com") else { return }
        let task = URLSession.shared.dataTask(with: url) { _, _, _ in
            // 只触发网络权限，不处理返回数据
        }
        task.resume()
    }
}

struct RootTabView: View {
    @AppStorage("defaultTab") private var defaultTab = "files"
    @State private var selection = "files"

    var body: some View {
        TabView(selection: $selection) {
            FileManagerView()
                .tabItem {
                    Label("文件", systemImage: "folder")
                }
                .tag("files")

            ContentView()
                .tabItem {
                    Label("传输", systemImage: "arrow.up.arrow.down")
                }
                .tag("transfer")
        }
        .onAppear {
            selection = defaultTab
        }
    }
}