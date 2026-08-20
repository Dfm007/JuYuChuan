import Foundation
import Swifter
import UIKit
import AVFoundation

struct FileInfo: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let url: URL

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

final class WebServerManager: ObservableObject {
    static let shared = WebServerManager()

    private let server = HttpServer()
    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - 音频保活相关
    private var audioPlayer: AVAudioPlayer?
    private let audioSession = AVAudioSession.sharedInstance()

    @Published var storagePath: URL {
        didSet {
            updateFileList()
        }
    }

    @Published var isRunning = false
    @Published var logMessages: [String] = []
    @Published var currentIP: String = "获取中..."
    @Published var currentPort: UInt16 = 8080
    @Published var files: [FileInfo] = []
    @Published var isUsingCustomPath = false

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storagePath = docs

        restoreCustomStorageIfNeeded()

        self.currentIP = Self.getIPAddress()
        setupRoutes()
        updateFileList()
    }

    private func restoreCustomStorageIfNeeded() {
        guard let bookmarkData = defaults.data(forKey: "storageBookmarkData") else { return }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)

            guard url.startAccessingSecurityScopedResource() else {
                defaults.removeObject(forKey: "storageBookmarkData")
                return
            }

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                url.stopAccessingSecurityScopedResource()
                defaults.removeObject(forKey: "storageBookmarkData")
                return
            }

            self.storagePath = url
            self.isUsingCustomPath = true

            if isStale {
                do {
                    let fresh = try url.bookmarkData(options: .minimalBookmark,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
                    defaults.set(fresh, forKey: "storageBookmarkData")
                } catch {
                    log("⚠️ 书签过期，重新保存失败: \(error.localizedDescription)")
                }
            }
        } catch {
            defaults.removeObject(forKey: "storageBookmarkData")
        }
    }

    // MARK: - 带时间戳的日志
    private func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        DispatchQueue.main.async {
            self.logMessages.append("[\(timestamp)] \(message)")
        }
    }

    // MARK: - 生成 WAV 静音数据
    private func generateSilentWAV(duration: TimeInterval = 0.5) -> Data? {
        let sampleRate: Double = 44100.0
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * Double(numChannels) * Double(bitsPerSample / 8)
        let blockAlign = numChannels * bitsPerSample / 8
        let numSamples = Int(sampleRate * duration)
        let dataSize = numSamples * Int(blockAlign)

        var header = Data()
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        let chunkSize = UInt32(36 + dataSize)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        let subchunk1Size: UInt32 = 16
        header.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        let audioFormat: UInt16 = 1
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        let sampleRateUInt32 = UInt32(sampleRate)
        header.append(contentsOf: withUnsafeBytes(of: sampleRateUInt32.littleEndian) { Data($0) })
        let byteRateUInt32 = UInt32(byteRate)
        header.append(contentsOf: withUnsafeBytes(of: byteRateUInt32.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        let subchunk2Size = UInt32(dataSize)
        header.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })

        let silenceData = Data(repeating: 0, count: dataSize)
        var wavData = Data()
        wavData.append(header)
        wavData.append(silenceData)
        return wavData
    }

    // MARK: - 音频保活控制
    private func startAudioKeepAlive() {
        stopAudioKeepAlive()

        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)

            guard let wavData = generateSilentWAV(duration: 0.5) else {
                log("⚠️ 生成静音数据失败")
                return
            }

            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            log("🎵 后台音频保活已启动")
        } catch {
            log("⚠️ 音频保活启动失败: \(error.localizedDescription)")
        }
    }

    private func stopAudioKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 静默忽略
        }
    }

    static func getIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "未连接WiFi" }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address ?? "未分配IP"
    }

    func updateFileList() {
        guard let items = try? fileManager.contentsOfDirectory(atPath: storagePath.path) else {
            DispatchQueue.main.async {
                self.files = []
            }
            return
        }
        var newFiles: [FileInfo] = []
        for path in items {
            let fullPath = storagePath.appendingPathComponent(path).path
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let size = attrs[.size] as? Int64 {
                    let url = URL(fileURLWithPath: fullPath)
                    newFiles.append(FileInfo(name: path, size: size, url: url))
                }
            }
        }
        newFiles.sort { $0.name < $1.name }
        DispatchQueue.main.async {
            self.files = newFiles
        }
    }

    func setStoragePath(_ url: URL) {
        let success = url.startAccessingSecurityScopedResource()
        if !success {
            log("⚠️ 无法访问所选目录，请检查权限")
            return
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            log("❌ 所选路径不是有效的目录")
            return
        }

        let testFile = url.appendingPathComponent(".writetest")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFile)
        } catch {
            url.stopAccessingSecurityScopedResource()
            log("❌ 所选目录不可写入: \(error.localizedDescription)")
            return
        }

        // 保存书签
        do {
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            defaults.set(bookmarkData, forKey: "storageBookmarkData")
        } catch {
            url.stopAccessingSecurityScopedResource()
            log("❌ 保存书签失败: \(error.localizedDescription)")
            return
        }

        isUsingCustomPath = true
        storagePath = url
        log("✅ 已切换存储目录至: \(url.lastPathComponent)")
    }

    func resetToDefaultStorage() {
        if isUsingCustomPath {
            storagePath.stopAccessingSecurityScopedResource()
            isUsingCustomPath = false
        }
        defaults.removeObject(forKey: "storageBookmarkData")
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        storagePath = docs
        log("🔄 已恢复默认存储目录")
    }

    // MARK: - App 内部删除文件（保留，供 ContentView 使用）
    func deleteFile(_ file: FileInfo) {
        let url = file.url
        do {
            try fileManager.removeItem(at: url)
            DispatchQueue.main.async {
                self.log("🗑️ 已删除文件: \(file.name)")
                self.updateFileList()
            }
        } catch {
            DispatchQueue.main.async {
                self.log("❌ 删除失败: \(file.name) - \(error.localizedDescription)")
            }
        }
    }

    // MARK: - HTTP 路由
    private func setupRoutes() {    
        server["/"] = { [weak self] _ in
            guard let self = self else { return .internalServerError }
            let html = self.generateHTML()
            return .ok(.html(html))
        }

        server["/download/:path"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            guard let filename = request.params[":path"]?
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return .badRequest(.text("文件名无效"))
            }
            let filePath = self.storagePath.appendingPathComponent(filename).path
            guard self.fileManager.fileExists(atPath: filePath) else {
                return .badRequest(.text("文件不存在"))
            }
            if let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                return .ok(.data(fileData, contentType: "application/octet-stream"))
            }
            return .internalServerError
        }

        server.POST["/upload"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            let multiparts = request.parseMultiPartFormData()
            guard !multiparts.isEmpty else {
                return .badRequest(.text("没有检测到上传的文件"))
            }
            var uploadedCount = 0
            for part in multiparts {
                guard let filename = part.fileName, !filename.isEmpty else { continue }
                let data = Data(part.body)
                let destinationPath = self.storagePath.appendingPathComponent(filename).path
                do {
                    try data.write(to: URL(fileURLWithPath: destinationPath))
                    uploadedCount += 1
                    DispatchQueue.main.async {
                        self.log("✅ 收到文件: \(filename)")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.log("❌ 保存失败: \(filename) - \(error.localizedDescription)")
                    }
                }
            }
            self.updateFileList()
            let result: [String: Any] = [
                "success": true,
                "count": uploadedCount
            ]
            return .ok(.json(result))
        }

        // 注意：网页端删除路由已移除

        server["/api/files"] = { [weak self] _ in
            guard let self = self else { return .internalServerError }
            let items = try? self.fileManager.contentsOfDirectory(atPath: self.storagePath.path)
            let fileInfos = items?.filter { path in
                var isDir: ObjCBool = false
                let fullPath = self.storagePath.appendingPathComponent(path).path
                self.fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
                return !isDir.boolValue
            }.map { filename -> [String: Any] in
                let fullPath = self.storagePath.appendingPathComponent(filename).path
                let attrs = try? self.fileManager.attributesOfItem(atPath: fullPath)
                let size = (attrs?[.size] as? Int64) ?? 0
                return [
                    "name": filename,
                    "size": size,
                    "url": "/download/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)"
                ]
            } ?? []
            let jsonData = try? JSONSerialization.data(withJSONObject: fileInfos)
            return .ok(.data(jsonData ?? Data(), contentType: "application/json"))
        }
    }

    private func generateHTML() -> String {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            return """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head><meta charset="UTF-8"><title>局域传</title></head>
            <body style="font-family:-apple-system;padding:40px;text-align:center;">
                <h2>页面加载失败</h2>
                <p>请确认 index.html 已包含在 App 资源中。</p>
            </body>
            </html>
            """
        }
        return html
    }

    func start(port: UInt16) throws {
        guard !isRunning else { return }
        currentPort = port

        startAudioKeepAlive()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.server.start(port, forceIPv4: true)
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.log("🚀 服务已启动于 \(self.currentIP):\(port)")
                    self.currentIP = Self.getIPAddress()
                    self.updateFileList()
                }
            } catch {
                DispatchQueue.main.async {
                    self.log("❌ 启动失败: \(error.localizedDescription)")
                    self.stopAudioKeepAlive()
                }
            }
        }
    }

    func stop() {
        server.stop()
        isRunning = false
        log("🛑 服务已停止")
        stopAudioKeepAlive()
    }
}
