import SwiftUI

@main
struct 局域传App: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            FileManagerView()
                .tabItem {
                    Label("文件", systemImage: "folder")
                }

            ContentView()
                .tabItem {
                    Label("传输", systemImage: "arrow.up.arrow.down")
                }
        }
    }
}
