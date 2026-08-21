import SwiftUI
import Foundation

struct TextEditView: View {
    let fileURL: URL
    var onSave: (() -> Void)?

    @State private var content = ""
    @State private var isLoaded = false
    @State private var isDirty = false
    @State private var saveError: String?
    @State private var showSaveError = false

    @Environment(\.dismiss) var dismiss

    var body: some View {
        Group {
            if isLoaded {
                TextEditor(text: $content)
                    .onChange(of: content) { _ in
                        isDirty = true
                    }
            } else {
                ProgressView("加载中...")
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    save()
                }
                .disabled(!isDirty)
            }
        }
        .onAppear(perform: load)
        .alert("保存失败", isPresented: $showSaveError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(saveError ?? "未知错误")
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            content = decode(data)
        } else {
            content = ""
        }
        isLoaded = true
    }

    private func decode(_ data: Data) -> String {
        // 先尝试 UTF-8
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 再尝试 GB18030（兼容 GBK / GB2312）
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) {
            return text
        }
        // 兜底：有损显示
        return String(decoding: data, as: UTF8.self)
    }

    private func save() {
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            isDirty = false
            onSave?()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            showSaveError = true
        }
    }
}
