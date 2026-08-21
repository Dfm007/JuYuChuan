import SwiftUI
import Foundation

// 文件管理页使用的条目类型（区分目录 / 文件）
struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int64

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// 文本类扩展名，点击进入编辑/查看
private let textExtensions: Set<String> = [
    "txt", "md", "log", "json", "xml", "csv", "swift", "plist",
    "strings", "conf", "ini", "yml", "yaml", "js", "html", "css"
]

// 压缩包扩展名（第一期只支持 zip）
private let archiveExtensions: Set<String> = ["zip"]

// MARK: - 文件管理入口
struct FileManagerView: View {
    @StateObject private var manager = WebServerManager.shared

    var body: some View {
        NavigationView {
            FileDirectoryView(directory: manager.storagePath, isRoot: true)
            .id(manager.storagePath.path)
        }
    }
}

// MARK: - 目录内容视图（支持递归进入子目录）
struct FileDirectoryView: View {
    let directory: URL
    var isRoot: Bool = false

    @State private var items: [FileItem] = []

    @State private var fileToDelete: FileItem?
    @State private var showDeleteAlert = false

    @State private var itemToRename: FileItem?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    @State private var archiveToExtract: FileItem?
    @State private var showPasswordPrompt = false
    @State private var passwordInput = ""

    @State private var showSettings = false

    @State private var errorMessage: String?
    @State private var showError = false

    private let fileManager = FileManager.default

    var body: some View {
        List {
            if items.isEmpty {
                Text("此文件夹为空")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
        .navigationTitle(isRoot ? "文件管理" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isRoot {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .onAppear {
            loadItems()
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                SettingsView()
            }
        }
        .alert("确认删除", isPresented: $showDeleteAlert) {
            Button("取消", role: .cancel) { fileToDelete = nil }
            Button("删除", role: .destructive) {
                if let item = fileToDelete {
                    delete(item)
                    fileToDelete = nil
                }
            }
        } message: {
            if let item = fileToDelete {
                Text("确定要删除 \"\(item.name)\" 吗？此操作不可撤销。")
            } else {
                Text("确定要删除吗？")
            }
        }
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("新名称", text: $renameText)
                .disableAutocorrection(true)
            Button("确定") {
                performRename()
            }
            Button("取消", role: .cancel) {
                itemToRename = nil
            }
        } message: {
            if let item = itemToRename {
                Text("当前名称：\(item.name)")
            } else {
                Text("请输入新名称")
            }
        }
        .alert("解压密码", isPresented: $showPasswordPrompt) {
            TextField("请输入密码", text: $passwordInput)
                .disableAutocorrection(true)
            Button("解压") {
                if let archive = archiveToExtract {
                    extract(archive, password: passwordInput.isEmpty ? nil : passwordInput)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let archive = archiveToExtract {
                Text("文件：\(archive.name)")
            } else {
                Text("请输入压缩包密码")
            }
        }
        .alert("出错了", isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    // MARK: - 行视图
    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        if item.isDirectory {
            NavigationLink {
                FileDirectoryView(directory: item.url)
            } label: {
                folderRow(item)
            }
            .swipeActions {
                itemActions(item)
            }
        } else if textExtensions.contains(fileExtension(item.name)) {
            NavigationLink {
                TextEditView(fileURL: item.url) {
                    loadItems()
                    WebServerManager.shared.updateFileList()
                }
            } label: {
                fileRow(item)
            }
            .swipeActions {
                itemActions(item)
            }
        } else if archiveExtensions.contains(fileExtension(item.name)) {
            Button {
                handleArchiveTap(item)
            } label: {
                fileRow(item)
            }
            .swipeActions {
                itemActions(item)
            }
        } else {
            fileRow(item)
                .swipeActions {
                    itemActions(item)
                }
        }
    }

    private func folderRow(_ item: FileItem) -> some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.blue)
            Text(item.name)
                .lineLimit(1)
        }
    }

    private func fileRow(_ item: FileItem) -> some View {
        HStack {
            Image(systemName: fileSystemIcon(for: item.name))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.sizeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 滑动操作
    @ViewBuilder
    private func itemActions(_ item: FileItem) -> some View {
        deleteButton(item)
        renameButton(item)
    }

    private func deleteButton(_ item: FileItem) -> some View {
        Button(role: .destructive) {
            fileToDelete = item
            showDeleteAlert = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func renameButton(_ item: FileItem) -> some View {
        Button {
            itemToRename = item
            renameText = item.name
            showRenameAlert = true
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        .tint(.blue)
    }

    // MARK: - 工具方法
    private func loadItems() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            items = []
            return
        }

        let mapped = urls.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let fileSize = Int64(values?.fileSize ?? 0)
            return FileItem(
                name: url.lastPathComponent,
                url: url,
                isDirectory: isDirectory,
                size: fileSize
            )
        }

        items = mapped.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func delete(_ item: FileItem) {
        do {
            try fileManager.removeItem(at: item.url)
            loadItems()
            WebServerManager.shared.updateFileList()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func performRename() {
        guard let item = itemToRename else { return }

        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            itemToRename = nil
            return
        }

        let parent = item.url.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(newName)

        if item.url.path == destination.path {
            itemToRename = nil
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            errorMessage = "已存在同名文件或文件夹"
            showError = true
            itemToRename = nil
            return
        }

        do {
            try fileManager.moveItem(at: item.url, to: destination)
            loadItems()
            WebServerManager.shared.updateFileList()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        itemToRename = nil
    }

    private func handleArchiveTap(_ item: FileItem) {
        if ArchiveManager.shared.isZipEncrypted(at: item.url) {
            archiveToExtract = item
            passwordInput = ""
            showPasswordPrompt = true
        } else {
            extract(item, password: nil)
        }
    }

    private func extract(_ archive: FileItem, password: String?) {
        let baseName = (archive.name as NSString).deletingPathExtension
        let destination = directory.appendingPathComponent(baseName)

        do {
            try ArchiveManager.shared.extractArchive(
                at: archive.url,
                to: destination,
                password: password
            )
            loadItems()
            WebServerManager.shared.updateFileList()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func fileExtension(_ filename: String) -> String {
        (filename as NSString).pathExtension.lowercased()
    }

    private func fileSystemIcon(for filename: String) -> String {
        switch fileExtension(filename) {
        case "pdf": return "doc.text"
        case "txt", "md", "log": return "doc.plaintext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "wav", "aac", "flac": return "music.note"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }
}
