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
        let ip = currentIP
        let port = currentPort
        return """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=yes">
    <title>局域传 · 文件传输</title>
    <style>
        :root {
            --bg: #05070d;
            --text: #f5f7fb;
            --text-dim: rgba(235, 240, 250, 0.62);
            --text-faint: rgba(235, 240, 250, 0.38);
            --accent: #0a84ff;
            --green: #30d158;
            --radius: 28px;
            --glass-bg: linear-gradient(135deg, rgba(255,255,255,0.11), rgba(255,255,255,0.045));
        }
        * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
        body {
            min-height: 100vh;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif;
            color: var(--text);
            background: var(--bg);
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 32px 16px;
            overflow-x: hidden;
            -webkit-font-smoothing: antialiased;
        }
        .bg {
            position: fixed;
            inset: 0;
            z-index: -2;
            overflow: hidden;
            background:
                radial-gradient(ellipse 120% 80% at 50% -20%, #0d1526 0%, transparent 60%),
                #05070d;
        }
        .orb {
            position: absolute;
            border-radius: 50%;
            filter: blur(90px);
            opacity: 0.55;
            will-change: transform;
            mix-blend-mode: screen;
        }
        .orb-1 {
            width: 46vw; height: 46vw;
            background: radial-gradient(circle at 30% 30%, #2b6cff, #5e5ce6 55%, transparent 72%);
            top: -12%; left: -8%;
            animation: drift1 26s ease-in-out infinite alternate;
        }
        .orb-2 {
            width: 40vw; height: 40vw;
            background: radial-gradient(circle at 60% 40%, #9b4dff, #d6397a 55%, transparent 72%);
            bottom: -14%; right: -8%;
            animation: drift2 32s ease-in-out infinite alternate;
        }
        .orb-3 {
            width: 34vw; height: 34vw;
            background: radial-gradient(circle at 50% 50%, #0ae2c8, #0a84ff 58%, transparent 74%);
            top: 38%; left: 52%;
            opacity: 0.4;
            animation: drift3 38s ease-in-out infinite alternate;
        }
        @keyframes drift1 {
            0%   { transform: translate(0, 0) scale(1); }
            50%  { transform: translate(12vw, 18vh) scale(1.18); }
            100% { transform: translate(-6vw, 8vh) scale(0.94); }
        }
        @keyframes drift2 {
            0%   { transform: translate(0, 0) scale(1); }
            50%  { transform: translate(-14vw, -10vh) scale(1.22); }
            100% { transform: translate(6vw, -16vh) scale(0.92); }
        }
        @keyframes drift3 {
            0%   { transform: translate(0, 0) scale(1) rotate(0deg); }
            50%  { transform: translate(-10vw, -12vh) scale(1.12) rotate(30deg); }
            100% { transform: translate(8vw, 10vh) scale(0.96) rotate(-20deg); }
        }
        .grain {
            position: fixed;
            inset: 0;
            z-index: -1;
            pointer-events: none;
            opacity: 0.05;
            background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.8' numOctaves='4'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
        }
        .glass {
            position: relative;
            background: var(--glass-bg);
            -webkit-backdrop-filter: blur(28px) saturate(180%);
            backdrop-filter: blur(28px) saturate(180%);
            border: 1px solid rgba(255,255,255,0.14);
            border-radius: var(--radius);
            box-shadow:
                0 20px 60px rgba(0,0,0,0.45),
                0 4px 16px rgba(0,0,0,0.25),
                inset 0 1px 0 rgba(255,255,255,0.22),
                inset 0 -1px 0 rgba(255,255,255,0.04);
            transition: transform 0.35s cubic-bezier(0.22, 1, 0.36, 1),
                        box-shadow 0.35s ease,
                        border-color 0.35s ease;
        }
        .glass::before {
            content: "";
            position: absolute;
            inset: 0;
            border-radius: inherit;
            padding: 1px;
            background: linear-gradient(
                130deg,
                rgba(255,255,255,0.42) 0%,
                rgba(255,255,255,0.08) 18%,
                rgba(255,255,255,0.02) 40%,
                rgba(255,255,255,0.10) 65%,
                rgba(255,255,255,0.35) 100%
            );
            -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
            -webkit-mask-composite: xor;
            mask-composite: exclude;
            pointer-events: none;
        }
        .glass::after {
            content: "";
            position: absolute;
            width: 55%;
            height: 45%;
            top: -18%;
            left: 10%;
            background: radial-gradient(ellipse, rgba(255,255,255,0.16), transparent 70%);
            border-radius: 50%;
            filter: blur(18px);
            pointer-events: none;
            animation: sheen 9s ease-in-out infinite alternate;
        }
        @keyframes sheen {
            0%   { transform: translateX(-6%) scale(1); opacity: 0.7; }
            100% { transform: translateX(60%) scale(1.25); opacity: 0.4; }
        }
        .glass:hover {
            border-color: rgba(255,255,255,0.24);
            box-shadow:
                0 28px 70px rgba(0,0,0,0.5),
                0 6px 20px rgba(0,0,0,0.28),
                inset 0 1px 0 rgba(255,255,255,0.3),
                inset 0 -1px 0 rgba(255,255,255,0.06);
            transform: translateY(-2px);
        }
        .container {
            width: 100%;
            max-width: 680px;
            display: flex;
            flex-direction: column;
            gap: 18px;
        }
        header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 8px 6px 4px;
        }
        .brand {
            display: flex;
            align-items: center;
            gap: 12px;
        }
        .brand-icon {
            width: 46px; height: 46px;
            display: grid;
            place-items: center;
            border-radius: 14px;
            font-size: 16px;
            font-weight: 700;
            color: #fff;
            background: linear-gradient(135deg, rgba(10,132,255,0.28), rgba(94,92,230,0.28));
            border: 1px solid rgba(255,255,255,0.18);
            box-shadow: inset 0 1px 0 rgba(255,255,255,0.25);
            -webkit-backdrop-filter: blur(14px);
            backdrop-filter: blur(14px);
        }
        .brand h1 {
            font-size: 24px;
            font-weight: 700;
            letter-spacing: -0.02em;
        }
        .brand p {
            font-size: 13px;
            color: var(--text-dim);
            margin-top: 2px;
        }
        .badge {
            display: inline-flex;
            align-items: center;
            gap: 7px;
            font-size: 13px;
            font-weight: 600;
            color: var(--green);
            padding: 8px 14px;
            border-radius: 999px;
            background: rgba(48,209,88,0.12);
            border: 1px solid rgba(48,209,88,0.28);
            -webkit-backdrop-filter: blur(12px);
            backdrop-filter: blur(12px);
        }
        .badge .dot {
            width: 7px; height: 7px;
            border-radius: 50%;
            background: var(--green);
            box-shadow: 0 0 10px var(--green);
            animation: pulse 2.2s ease-in-out infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; transform: scale(1); }
            50%      { opacity: 0.5; transform: scale(0.8); }
        }
        .card-addr {
            padding: 20px 22px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 14px;
            flex-wrap: wrap;
        }
        .addr-left {
            display: flex;
            align-items: center;
            gap: 14px;
            min-width: 0;
        }
        .addr-left .glyph {
            font-size: 13px;
            font-weight: 700;
            color: var(--text-dim);
            letter-spacing: 0.04em;
        }
        .addr-text {
            font-family: "SF Mono", "SFMono-Regular", ui-monospace, Menlo, Consolas, monospace;
            font-size: 17px;
            font-weight: 600;
            color: #dbe6ff;
            word-break: break-all;
            letter-spacing: 0.01em;
        }
        .addr-label {
            font-size: 12px;
            color: var(--text-faint);
            margin-bottom: 3px;
            letter-spacing: 0.06em;
            text-transform: uppercase;
        }
        .copy-btn {
            flex-shrink: 0;
            border: none;
            cursor: pointer;
            color: var(--text);
            font-size: 14px;
            font-weight: 600;
            padding: 10px 18px;
            border-radius: 14px;
            background: rgba(255,255,255,0.09);
            border: 1px solid rgba(255,255,255,0.16);
            -webkit-backdrop-filter: blur(10px);
            backdrop-filter: blur(10px);
            transition: all 0.25s ease;
        }
        .copy-btn:hover {
            background: rgba(255,255,255,0.16);
            border-color: rgba(255,255,255,0.3);
            transform: scale(1.04);
        }
        .copy-btn:active { transform: scale(0.96); }
        .card-upload {
            padding: 28px 24px;
            text-align: center;
        }
        .card-upload h2 {
            font-size: 20px;
            font-weight: 700;
            letter-spacing: -0.01em;
        }
        .card-upload .sub {
            margin-top: 6px;
            font-size: 14px;
            color: var(--text-dim);
        }
        .dropzone {
            margin-top: 18px;
            padding: 38px 18px;
            border-radius: 22px;
            border: 1.5px dashed rgba(255,255,255,0.22);
            background: rgba(255,255,255,0.04);
            transition: all 0.3s ease;
            cursor: pointer;
        }
        .dropzone .big {
            font-size: 16px;
            font-weight: 700;
            margin-bottom: 10px;
            color: var(--text-dim);
            letter-spacing: 0.08em;
            transition: transform 0.3s ease;
        }
        .dropzone p { font-size: 15px; font-weight: 600; }
        .dropzone .hint { font-size: 13px; color: var(--text-faint); margin-top: 6px; }
        .dropzone.dragover {
            border-color: var(--accent);
            background: rgba(10,132,255,0.1);
            box-shadow: 0 0 0 4px rgba(10,132,255,0.15), inset 0 0 30px rgba(10,132,255,0.06);
        }
        .dropzone.dragover .big { transform: translateY(-6px) scale(1.15); }
        .dropzone:hover { border-color: rgba(255,255,255,0.4); }
        #uploadProgress {
            margin-top: 16px;
            display: none;
        }
        #uploadProgress .track {
            width: 100%;
            background: rgba(255,255,255,0.08);
            border-radius: 8px;
            overflow: hidden;
            height: 8px;
        }
        #uploadProgress .bar {
            width: 0%;
            height: 100%;
            background: var(--accent);
            border-radius: 8px;
            transition: width 0.3s;
        }
        #uploadProgress .status-text {
            display: block;
            margin-top: 6px;
            font-size: 14px;
            color: var(--text-dim);
        }
        .card-files { padding: 22px; }
        .card-files .head-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 16px;
        }
        .card-files h2 { font-size: 18px; font-weight: 700; }
        .count-pill {
            font-size: 12px;
            color: var(--text-dim);
            padding: 5px 12px;
            border-radius: 999px;
            background: rgba(255,255,255,0.06);
            border: 1px solid rgba(255,255,255,0.1);
        }
        .file-item {
            display: flex;
            align-items: center;
            gap: 14px;
            padding: 13px 14px;
            border-radius: 18px;
            margin-bottom: 10px;
            background: rgba(255,255,255,0.05);
            border: 1px solid rgba(255,255,255,0.08);
            transition: all 0.25s ease;
        }
        .file-item:last-child { margin-bottom: 0; }
        .file-item:hover {
            background: rgba(255,255,255,0.09);
            border-color: rgba(255,255,255,0.18);
            transform: translateX(3px);
        }
        .file-icon {
            width: 42px; height: 42px;
            flex-shrink: 0;
            display: grid;
            place-items: center;
            border-radius: 12px;
            font-size: 12px;
            font-weight: 700;
            color: #fff;
            background: linear-gradient(135deg, rgba(10,132,255,0.22), rgba(94,92,230,0.22));
            border: 1px solid rgba(255,255,255,0.14);
        }
        .file-meta { flex: 1; min-width: 0; }
        .file-name {
            font-size: 15px;
            font-weight: 600;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        .file-size { font-size: 12px; color: var(--text-faint); margin-top: 3px; }
        .file-dl {
            flex-shrink: 0;
            text-decoration: none;
            color: var(--text);
            font-size: 13px;
            font-weight: 600;
            padding: 9px 16px;
            border-radius: 12px;
            background: rgba(255,255,255,0.08);
            border: 1px solid rgba(255,255,255,0.14);
            transition: all 0.25s ease;
        }
        .file-dl:hover {
            background: var(--accent);
            border-color: var(--accent);
            color: #fff;
            box-shadow: 0 4px 18px rgba(10,132,255,0.45);
        }
        .empty {
            text-align: center;
            padding: 38px 0 30px;
            color: var(--text-faint);
            font-size: 14px;
        }
        .empty .big { font-size: 16px; font-weight: 700; display: block; margin-bottom: 10px; opacity: 0.7; }
        footer {
            text-align: center;
            font-size: 12px;
            color: var(--text-faint);
            padding: 6px 0 10px;
            letter-spacing: 0.02em;
        }
        @media (max-width: 480px) {
            body { padding: 18px 10px; }
            .card-addr { padding: 16px; }
            .addr-text { font-size: 14px; }
            .brand h1 { font-size: 20px; }
        }
    </style>
</head>
<body>

<div class="bg">
    <div class="orb orb-1"></div>
    <div class="orb orb-2"></div>
    <div class="orb orb-3"></div>
</div>
<div class="grain"></div>

<div class="container">

    <header>
        <div class="brand">
            <div class="brand-icon">传</div>
            <div>
                <h1>局域传</h1>
                <p>文件枢纽</p>
            </div>
        </div>
        <span class="badge"><span class="dot"></span>在线</span>
    </header>

    <section class="glass card-addr">
        <div class="addr-left">
            <span class="glyph">链接</span>
            <div>
                <div class="addr-label">局域网地址</div>
                <div class="addr-text" id="addrText">\(ip):\(port)</div>
            </div>
        </div>
        <button class="copy-btn" id="copyBtn">复制</button>
    </section>

    <section class="glass card-upload">
        <h2>上传到手机</h2>
        <p class="sub">选择文件，立即保存到 iPhone 本地</p>
        <div class="dropzone" id="dropZone">
            <div class="big">文件夹</div>
            <p>点击选择 或 拖拽文件至此</p>
            <div class="hint">支持多文件同时上传</div>
        </div>
        <input type="file" id="fileInput" multiple style="display:none">
        <div id="uploadProgress">
            <div class="track"><div class="bar" id="progressBar"></div></div>
            <span class="status-text" id="progressText">0%</span>
        </div>
    </section>

    <section class="glass card-files">
        <div class="head-row">
            <h2>最近文件</h2>
            <span class="count-pill" id="countPill">0 个文件</span>
        </div>
        <div id="fileList"></div>
    </section>

    <footer>局域传 · 点对点局域网传输 · 数据不经过云端</footer>
</div>

<script>
    var fileInput = document.getElementById('fileInput');
    var dropZone = document.getElementById('dropZone');
    var fileList = document.getElementById('fileList');
    var countPill = document.getElementById('countPill');
    var progressContainer = document.getElementById('uploadProgress');
    var progressBar = document.getElementById('progressBar');
    var progressText = document.getElementById('progressText');

    function formatSize(bytes) {
        if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + ' MB';
        if (bytes >= 1024) return (bytes / 1024).toFixed(0) + ' KB';
        return bytes + ' B';
    }

    function fileIconFor(name) {
        var ext = name.split('.').pop().toLowerCase();
        if (['mp4','mov','m4v'].indexOf(ext) >= 0) return '影';
        if (['mp3','wav','aac','flac'].indexOf(ext) >= 0) return '音';
        if (['jpg','jpeg','png','gif','heic','webp'].indexOf(ext) >= 0) return '图';
        if (['pdf'].indexOf(ext) >= 0) return '文';
        if (['zip','rar','7z','tar','gz'].indexOf(ext) >= 0) return '包';
        return '件';
    }

    function escapeHtml(text) {
        var div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    function loadFileList() {
        fetch('/api/files')
            .then(function(res) { return res.json(); })
            .then(function(files) {
                countPill.textContent = files.length + ' 个文件';
                if (files.length === 0) {
                    fileList.innerHTML = '<div class="empty"><span class="big">空</span>暂无文件，上传一个试试</div>';
                    return;
                }
                fileList.innerHTML = files.map(function(f) {
                    return '<div class="file-item">' +
                        '<div class="file-icon">' + fileIconFor(f.name) + '</div>' +
                        '<div class="file-meta">' +
                            '<div class="file-name">' + escapeHtml(f.name) + '</div>' +
                            '<div class="file-size">' + formatSize(f.size) + '</div>' +
                        '</div>' +
                        '<a class="file-dl" href="' + f.url + '">下载</a>' +
                    '</div>';
                }).join('');
            })
            .catch(function() {
                fileList.innerHTML = '<div class="empty"><span class="big">错</span>加载失败，请刷新</div>';
            });
    }

    function uploadFiles(files) {
        var formData = new FormData();
        for (var i = 0; i < files.length; i++) {
            formData.append('file', files[i]);
        }

        progressContainer.style.display = 'block';
        progressBar.style.width = '0%';
        progressBar.style.background = '#0a84ff';
        progressText.textContent = '0%';

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/upload', true);

        xhr.upload.onprogress = function(e) {
            if (e.lengthComputable) {
                var pct = Math.round((e.loaded / e.total) * 100);
                progressBar.style.width = pct + '%';
                progressText.textContent = pct + '%';
            }
        };

        xhr.onload = function() {
            if (xhr.status === 200) {
                try {
                    var response = JSON.parse(xhr.responseText);
                    if (response.success) {
                        progressBar.style.background = '#30d158';
                        progressText.textContent = '成功上传 ' + response.count + ' 个文件';
                    } else {
                        progressBar.style.background = '#ff3b30';
                        progressText.textContent = '上传失败: ' + (response.message || '未知错误');
                    }
                } catch (e) {
                    progressBar.style.background = '#ff3b30';
                    progressText.textContent = '上传失败，服务器响应异常';
                }
                loadFileList();
            } else {
                progressBar.style.background = '#ff3b30';
                progressText.textContent = '上传失败: ' + xhr.status;
            }
            setTimeout(function() {
                progressContainer.style.display = 'none';
                progressBar.style.background = '#0a84ff';
            }, 4000);
        };

        xhr.onerror = function() {
            progressBar.style.background = '#ff3b30';
            progressText.textContent = '上传失败，网络错误';
            setTimeout(function() {
                progressContainer.style.display = 'none';
                progressBar.style.background = '#0a84ff';
            }, 4000);
        };

        xhr.send(formData);
    }

    document.getElementById('copyBtn').addEventListener('click', function() {
        var addr = document.getElementById('addrText').textContent;
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(addr).then(function() {
                this.textContent = '已复制';
                var btn = this;
                setTimeout(function() { btn.textContent = '复制'; }, 1400);
            }.bind(this));
        } else {
            var ta = document.createElement('textarea');
            ta.value = addr;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try { document.execCommand('copy'); } catch (e) {}
            document.body.removeChild(ta);
            this.textContent = '已复制';
            var btn = this;
            setTimeout(function() { btn.textContent = '复制'; }, 1400);
        }
    });

    fileInput.addEventListener('change', function() {
        if (this.files.length > 0) {
            uploadFiles(this.files);
            this.value = '';
        }
    });

    dropZone.addEventListener('dragover', function(e) {
        e.preventDefault();
        dropZone.classList.add('dragover');
    });
    dropZone.addEventListener('dragleave', function() {
        dropZone.classList.remove('dragover');
    });
    dropZone.addEventListener('drop', function(e) {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        if (e.dataTransfer.files.length > 0) {
            uploadFiles(e.dataTransfer.files);
        }
    });
    dropZone.addEventListener('click', function() {
        fileInput.click();
    });

    loadFileList();
    setInterval(loadFileList, 10000);
</script>
</body>
</html>
"""
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
