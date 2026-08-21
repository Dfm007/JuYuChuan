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

    var body: some View {
        Group {
            if isLoaded {
                if isEditing {
                    TextEditor(text: $content)
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
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

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
