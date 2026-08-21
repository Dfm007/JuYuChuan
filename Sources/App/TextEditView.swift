import SwiftUI
import Foundation

struct TextEditView: View {
    let fileURL: URL
    var allowsEditing: Bool = true
    var onSave: (() -> Void)?

    @State private var content = ""
    @State private var isLoaded = false
    @State private var isEditing = false
    @State private var saveError: String?
    @State private var showSaveError = false

    private let maxTextFileSize = 10 * 1024 * 1024   // 10 MB

    var body: some View {
        Group {
            if isLoaded {
                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                } else {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            } else {
                ProgressView("加载中...")
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if allowsEditing {
                    if isEditing {
                        Button("保存") {
                            save()
                        }
                    } else {
                        Button("编辑") {
                            isEditing = true
                        }
                    }
                }
            }
        }
        .onAppear {
            // 延后到主线程下一帧，避免 sheet 弹出瞬间视图状态竞争
            DispatchQueue.main.async {
                load()
            }
        }
        .alert("保存失败", isPresented: $showSaveError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(saveError ?? "未知错误")
        }
    }

    // MARK: - 加载
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            content = "无法读取文件。"
            isLoaded = true
            return
        }

        if data.isEmpty {
            content = "(文件为空)"
            isLoaded = true
            return
        }

        if data.count > maxTextFileSize {
            content = "文件过大，无法以文本形式打开。\n\n文件大小：\(sizeString(data.count))"
            isLoaded = true
            return
        }

        content = decode(data)
        isLoaded = true
    }

    private func sizeString(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    // MARK: - 解码（按概率从高到低尝试）
    private func decode(_ data: Data) -> String {
        // 1. UTF-8
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        // 2. UTF-16（自动处理 LE / BE 的 BOM）
        if let text = String(data: data, encoding: .utf16) {
            return text
        }

        // 3. 无 BOM 的 UTF-16 LE（PowerShell 旧版常见）
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }

        // 4. 无 BOM 的 UTF-16 BE
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return text
        }

        // 5. GB18030（兼容 GBK / GB2312）
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) {
            return text
        }

        // 6. 都失败，判断是否二进制
        if looksLikeBinary(data) {
            return "此文件不是文本文件，无法显示内容。"
        }

        return "无法识别此文件的文本编码。"
    }

    /// 检测二进制：前 8000 字节中 NUL 字节占比过高
    private func looksLikeBinary(_ data: Data) -> Bool {
        let sampleCount = min(data.count, 8000)
        guard sampleCount > 0 else { return false }

        var nullCount = 0
        for i in 0..<sampleCount {
            if data[i] == 0 {
                nullCount += 1
            }
        }
        return Double(nullCount) / Double(sampleCount) > 0.05
    }

    // MARK: - 保存
    private func save() {
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            isEditing = false
            onSave?()
        } catch {
            saveError = error.localizedDescription
            showSaveError = true
        }
    }
}
