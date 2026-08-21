import SwiftUI
import UIKit

// MARK: - 只读大文本视图（UITextView，性能远优于 SwiftUI Text）
struct TextViewOnly: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

// MARK: - 文本查看 / 编辑
struct TextEditView: View {
    let fileURL: URL
    var allowsEditing: Bool = true
    var onSave: (() -> Void)?

    @State private var content = ""
    @State private var isLoaded = false
    @State private var isEditing = false
    @State private var saveError: String?
    @State private var showSaveError = false

    // 超过此大小不再读取，防止极端大文件拖垮内存
    private let maxTextFileSize = 50 * 1024 * 1024   // 50 MB

    var body: some View {
        Group {
            if isLoaded {
                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                } else {
                    TextViewOnly(text: content)
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
            // 后台加载，避免主线程卡顿
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = Self.loadContent(from: fileURL, maxSize: maxTextFileSize)
                DispatchQueue.main.async {
                    content = loaded
                    isLoaded = true
                }
            }
        }
        .alert("保存失败", isPresented: $showSaveError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(saveError ?? "未知错误")
        }
    }

    // MARK: - 读取（后台调用）
    private static func loadContent(from url: URL, maxSize: Int) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "无法读取文件。"
        }

        if data.isEmpty {
            return "(文件为空)"
        }

        if data.count > maxSize {
            return "文件过大，无法以文本形式打开。\n\n文件大小：\(sizeString(data.count))"
        }

        return decode(data)
    }

    private static func sizeString(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    // MARK: - 解码
    private static func decode(_ data: Data) -> String {
        // 1. UTF-8
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        // 2. UTF-16（自动处理带 BOM 的 LE / BE）
        if let text = String(data: data, encoding: .utf16) {
            return text
        }

        // 3. UTF-16 LE（无 BOM，PowerShell 旧版常见）
        if let text = String(data: data, encoding: .utf16LittleEndian) {
            return text
        }

        // 4. UTF-16 BE（无 BOM）
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

        // 6. 二进制兜底
        return "无法识别此文件的文本编码。"
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
