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
            saveBookmark()
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

        // 尝试从 UserDefaults 恢复书签
        if let bookmarkData = defaults.data(forKey: "storageBookmarkData") {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                if !isStale {
                    if url.startAccessingSecurityScopedResource() {
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            self.storagePath = url
                            self.isUsingCustomPath = true
                        } else {
                            url.stopAccessingSecurityScopedResource()
                            defaults.removeObject(forKey: "storageBookmarkData")
                        }
                    } else {
                        defaults.removeObject(forKey: "storageBookmarkData")
                    }
                } else {
                    defaults.removeObject(forKey: "storageBookmarkData")
                }
            } catch {
                defaults.removeObject(forKey: "storageBookmarkData")
            }
        }

        self.currentIP = Self.getIPAddress()
        setupRoutes()
        updateFileList()
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

    // MARK: - 书签持久化
    private func saveBookmark() {
        if isUsingCustomPath {
            do {
                let bookmarkData = try storagePath.bookmarkData(options: .minimalBookmark,
                                                               includingResourceValuesForKeys: nil,
                                                               relativeTo: nil)
                defaults.set(bookmarkData, forKey: "storageBookmarkData")
            } catch {
                log("❌ 保存书签失败: \(error.localizedDescription)")
            }
        } else {
            defaults.removeObject(forKey: "storageBookmarkData")
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
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #f2f4f8;
            color: #1c1e24;
            padding: 20px;
            max-width: 700px;
            margin: 0 auto;
        }
        .card {
            background: white;
            border-radius: 24px;
            padding: 24px 20px;
            margin-bottom: 20px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.04);
            border: 1px solid #e9ecf0;
        }
        h1 { font-size: 28px; font-weight: 700; display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
        h1 small { font-size: 16px; font-weight: 400; color: #6b7280; }
        .addr-box {
            background: #f0f3f7;
            padding: 14px 18px;
            border-radius: 16px;
            font-family: monospace;
            font-size: 18px;
            font-weight: 500;
            word-break: break-all;
            display: flex;
            align-items: center;
            justify-content: space-between;
            flex-wrap: wrap;
            gap: 10px;
            margin: 12px 0 4px 0;
        }
        .badge { background: #34c759; color: white; padding: 4px 12px; border-radius: 20px; font-size: 14px; font-weight: 600; }
        .upload-area {
            border: 2px dashed #cdd2db;
            border-radius: 20px;
            padding: 30px 15px;
            text-align: center;
            transition: 0.2s;
            margin-top: 8px;
        }
        .upload-area.dragover { background: #eaf5ff; border-color: #007aff; }
        .upload-btn { display: inline-block; background: #007aff; color: white; padding: 12px 32px; border-radius: 40px; font-weight: 600; cursor: pointer; border: none; font-size: 17px; margin-top: 10px; }
        .upload-btn:hover { background: #0066d9; }
        #fileInput { display: none; }
        .file-list { margin-top: 16px; }
        .file-item {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 12px 14px;
            background: #f8f9fc;
            border-radius: 14px;
            margin-bottom: 8px;
            transition: 0.1s;
            border: 1px solid transparent;
        }
        .file-item:hover { background: #eef2f7; border-color: #dce1e9; }
        .file-name { font-weight: 500; flex: 1; word-break: break-all; margin-right: 12px; }
        .file-size { color: #6b7280; font-size: 14px; margin-right: 12px; white-space: nowrap; }
        .file-download { background: white; border: 1px solid #d0d5dd; padding: 6px 16px; border-radius: 30px; font-size: 14px; font-weight: 500; text-decoration: none; color: #1c1e24; white-space: nowrap; }
        .file-download:hover { background: #007aff; color: white; border-color: #007aff; }
        .empty-msg { color: #8e95a3; text-align: center; padding: 30px 0 10px 0; font-size: 16px; }
        .footer { font-size: 13px; color: #8e95a3; text-align: center; margin-top: 30px; }
        #uploadProgress { margin-top: 10px; font-weight: 500; color: #007aff; display: none; }
        #uploadProgress .track { width: 100%; background: #e9ecf0; border-radius: 8px; overflow: hidden; height: 8px; }
        #uploadProgress .bar { width: 0%; height: 100%; background: #007aff; border-radius: 8px; transition: width 0.3s; }
        #uploadProgress .status-text { display: block; margin-top: 4px; font-size: 14px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>📤 局域传 <small>文件枢纽</small></h1>
        <div class="addr-box">
            <span>🔗 \(ip):\(port)</span>
            <span class="badge">● 在线</span>
        </div>
    </div>

    <div class="card" id="uploadCard">
        <h3 style="margin-bottom: 6px;">📥 上传到手机</h3>
        <p style="color:#6b7280; font-size:15px; margin-bottom:12px;">选择文件，立即保存到 iPhone 本地</p>
        <div class="upload-area" id="dropZone">
            <div style="font-size:44px; margin-bottom:8px;">📁</div>
            <p style="margin-bottom:4px; font-weight:500;">点击选择 或 拖拽文件至此</p>
            <p style="font-size:14px; color:#8e95a3; margin-bottom:12px;">支持多文件同时上传</p>
            <label class="upload-btn" for="fileInput">📤 选择文件</label>
            <input type="file" id="fileInput" multiple>
        </div>
        <div id="uploadProgress">
            <div class="track"><div class="bar" id="progressBar"></div></div>
            <span class="status-text" id="progressText">0%</span>
        </div>
    </div>

    <div class="card" id="listCard">
        <h3 style="margin-bottom: 6px;">📂 手机内文件</h3>
        <p style="color:#6b7280; font-size:15px; margin-bottom:12px;">点击右侧「下载」即可保存到您的其他设备</p>
        <div id="fileListContainer">
            <div class="empty-msg">⏳ 加载中...</div>
        </div>
    </div>
    <div class="footer">局域传 · 仅限同一局域网 · 传输不上传至任何云端</div>

    <script>
        const fileInput = document.getElementById('fileInput');
        const dropZone = document.getElementById('dropZone');
        const fileListContainer = document.getElementById('fileListContainer');
        const progressContainer = document.getElementById('uploadProgress');
        const progressBar = document.getElementById('progressBar');
        const progressText = document.getElementById('progressText');

        function loadFileList() {
            fetch('/api/files')
                .then(res => res.json())
                .then(files => {
                    if (files.length === 0) {
                        fileListContainer.innerHTML = '<div class="empty-msg">📭 手机里暂无文件，上传一个吧</div>';
                        return;
                    }
                    let html = '<div class="file-list">';
                    files.forEach(f => {
                        const sizeStr = f.size > 1024*1024 ? (f.size/1024/1024).toFixed(1) + ' MB' : (f.size/1024).toFixed(1) + ' KB';
                        html += `
                            <div class="file-item">
                                <span class="file-name">📄 ${escapeHtml(f.name)}</span>
                                <span class="file-size">${sizeStr}</span>
                                <a href="${f.url}" class="file-download" download>⬇️ 下载</a>
                            </div>
                        `;
                    });
                    html += '</div>';
                    fileListContainer.innerHTML = html;
                })
                .catch(() => { fileListContainer.innerHTML = '<div class="empty-msg">⚠️ 加载失败，请刷新</div>'; });
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function uploadFiles(files) {
            const formData = new FormData();
            for (let i=0; i<files.length; i++) {
                formData.append('file', files[i]);
            }
            const xhr = new XMLHttpRequest();

            progressContainer.style.display = 'block';
            progressBar.style.width = '0%';
            progressBar.style.background = '#007aff';
            progressText.textContent = '0%';

            xhr.open('POST', '/upload', true);

            xhr.upload.onprogress = function(e) {
                if (e.lengthComputable) {
                    const percent = Math.round((e.loaded / e.total) * 100);
                    progressBar.style.width = percent + '%';
                    progressText.textContent = percent + '%';
                }
            };

            xhr.onload = function() {
                if (xhr.status === 200) {
                    try {
                        const response = JSON.parse(xhr.responseText);
                        if (response.success) {
                            progressBar.style.background = '#34c759';
                            progressText.textContent = '✅ 成功上传 ' + response.count + ' 个文件！';
                        } else {
                            progressBar.style.background = '#ff3b30';
                            progressText.textContent = '❌ 上传失败: ' + (response.message || '未知错误');
                        }
                    } catch (e) {
                        progressBar.style.background = '#ff3b30';
                        progressText.textContent = '❌ 上传失败，服务器响应异常';
                    }
                    loadFileList();
                } else {
                    progressBar.style.background = '#ff3b30';
                    progressText.textContent = '❌ 上传失败: ' + xhr.status;
                }
                setTimeout(() => {
                    progressContainer.style.display = 'none';
                    progressBar.style.background = '#007aff';
                }, 5000);
            };

            xhr.onerror = function() {
                progressBar.style.background = '#ff3b30';
                progressText.textContent = '❌ 上传失败，网络错误';
                setTimeout(() => {
                    progressContainer.style.display = 'none';
                    progressBar.style.background = '#007aff';
                }, 5000);
            };

            xhr.send(formData);
        }

        fileInput.addEventListener('change', function(e) {
            if (this.files.length > 0) {
                uploadFiles(this.files);
                this.value = '';
            }
        });

        dropZone.addEventListener('dragover', (e) => {
            e.preventDefault();
            dropZone.classList.add('dragover');
        });
        dropZone.addEventListener('dragleave', () => {
            dropZone.classList.remove('dragover');
        });
        dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            dropZone.classList.remove('dragover');
            if (e.dataTransfer.files.length > 0) {
                uploadFiles(e.dataTransfer.files);
            }
        });
        dropZone.addEventListener('click', (e) => {
            if (e.target.tagName !== 'LABEL' && e.target.tagName !== 'INPUT') {
                fileInput.click();
            }
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
