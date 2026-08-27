import SwiftUI
import UIKit

// MARK: - 文件夹选择器
struct FolderPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FolderPicker

        init(parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.onPick(url)
            }
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - 导出文件
struct DocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onDismiss: (() -> Void)?
        init(onDismiss: (() -> Void)?) {
            self.onDismiss = onDismiss
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss?()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?()
        }
    }
}

// MARK: - 设置界面
struct SettingsView: View {
    @StateObject private var manager = WebServerManager.shared
    @State private var showFolderPicker = false
    @State private var showResetAlert = false
    @Environment(\.dismiss) var dismiss
    @AppStorage("defaultTab") private var defaultTab = "files"

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前存储位置")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(manager.storagePath.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if manager.isUsingCustomPath {
                        Text("自定义")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    } else {
                        Text("默认")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                }

                HStack {
                    Button("恢复默认") {
                        showResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .disabled(!manager.isUsingCustomPath)

                    Spacer()

                    Button("选择自定义目录") {
                        showFolderPicker = true
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("存储设置")
            } footer: {
                Text("上传的文件将保存在所选目录中。选择自定义目录后，App 重启后仍会记住该位置。")
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("作者")
                    Spacer()
                    Text("DeepSeek v4 flash")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("关于")
            }

            Section {
                Picker("启动页", selection: $defaultTab) {
                    Text("文件管理").tag("files")
                    Text("局域传").tag("transfer")
                }
            } header: {
                Text("首页设置")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(isPresented: $showFolderPicker) { url in
                manager.setStoragePath(url)
            }
        }
        .alert("恢复默认存储位置", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) { }
            Button("恢复", role: .destructive) {
                manager.resetToDefaultStorage()
            }
        } message: {
            Text("将存储位置恢复为 App 默认的 Documents 目录。当前目录中的文件不会丢失。")
        }
    }
}

// MARK: - 主视图
struct ContentView: View {
    @StateObject private var manager = WebServerManager.shared
    @State private var inputPort: String = "8080"
    @State private var showSettings = false
    @State private var showAllLogs = false

    var body: some View {
        NavigationView {
            List {
                // 服务信息
                Section {
                    HStack {
                        Image(systemName: "wifi")
                            .foregroundColor(manager.isRunning ? .green : .gray)
                        Text("局域网地址")
                            .fontWeight(.medium)
                        Spacer()
                        Text(manager.currentIP)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("端口", text: $inputPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .disabled(manager.isRunning)
                        if manager.isRunning {
                            Text("(运行中)")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                } header: {
                    Text("服务信息")
                }

                // 控制按钮
                Section {
                    if manager.isRunning {
                        Button(action: manager.stop) {
                            HStack {
                                Spacer()
                                Label("停止服务", systemImage: "stop.circle")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    } else {
                        Button(action: {
                            guard let port = UInt16(inputPort), port > 0 else {
                                manager.logMessages.append("⚠️ 请输入有效端口 (1-65535)")
                                return
                            }
                            do {
                                try manager.start(port: port)
                            } catch {
                                manager.logMessages.append("❌ 启动失败: \(error.localizedDescription)")
                            }
                        }) {
                            HStack {
                                Spacer()
                                Label("启动服务", systemImage: "play.circle")
                                    .foregroundColor(.blue)
                                Spacer()
                            }
                        }
                        .disabled(manager.isRunning)
                    }
                }

                // 运行日志
                Section {
                    if manager.logMessages.isEmpty {
                        Text("暂无日志")
                            .foregroundColor(.secondary)
                    } else {
                        if let lastLog = manager.logMessages.last {
                            Text(lastLog)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.vertical, 2)
                        }

                        if showAllLogs {
                            ForEach(manager.logMessages.dropLast(), id: \.self) { msg in
                                Text(msg)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(.vertical, 2)
                            }
                        }

                        if manager.logMessages.count > 1 {
                            Button(action: {
                                withAnimation {
                                    showAllLogs.toggle()
                                }
                            }) {
                                HStack {
                                    Spacer()
                                    Text(showAllLogs ? "▲ 收起全部" : "▼ 展开更多 (\(manager.logMessages.count - 1) 条)")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                        }
                    }
                } header: {
                    Text("运行日志")
                }

                // 使用指南
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("使用指南")
                            .font(.headline)
                        Text("1. 点击「启动服务」，确保手机和电脑/其他设备连在同一个WiFi")
                        Text("2. 在其他设备的浏览器输入上方显示的地址（例如 192.168.0.100:8080）")
                        Text("3. 网页内可上传文件到手机，或点击下载手机里的文件")
                        Text("4. 手机内文件可通过文件管理页查看、编辑、重命名或删除")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("局域传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .refreshable {
                manager.currentIP = WebServerManager.getIPAddress()
                manager.updateFileList()
            }
            .sheet(isPresented: $showSettings) {
                NavigationView {
                    SettingsView()
                }
            }
        }
    }
}
