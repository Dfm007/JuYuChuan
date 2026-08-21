import Foundation
import ZipArchive

enum ArchiveError: LocalizedError {
    case unsupportedFormat
    case extractionFailed
    case wrongPassword

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "暂不支持此压缩格式"
        case .extractionFailed:
            return "解压失败"
        case .wrongPassword:
            return "密码错误或文件损坏"
        }
    }
}

final class ArchiveManager {
    static let shared = ArchiveManager()

    private let fileManager = FileManager.default

    func isSupportedArchive(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext == "zip"
    }

    /// 判断 zip 是否加密（读取 central directory 的 general purpose bit flag）
    func isZipEncrypted(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let bytes = [UInt8](data)
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 0x50,
               bytes[i + 1] == 0x4B,
               bytes[i + 2] == 0x01,
               bytes[i + 3] == 0x02 {
                let flagIndex = i + 8
                if flagIndex + 1 < bytes.count {
                    let flag = UInt16(bytes[flagIndex]) | (UInt16(bytes[flagIndex + 1]) << 8)
                    if flag & 0x0001 != 0 {
                        return true
                    }
                }
            }
            i += 1
        }
        return false
    }

    func extractArchive(at sourceURL: URL, to destinationURL: URL, password: String?) throws {
        let ext = (sourceURL.lastPathComponent as NSString).pathExtension.lowercased()

        switch ext {
        case "zip":
            try extractZip(at: sourceURL, to: destinationURL, password: password)
        default:
            throw ArchiveError.unsupportedFormat
        }
    }

    private func extractZip(at sourceURL: URL, to destinationURL: URL, password: String?) throws {
        // 有密码 → SSZipArchive（支持 AES / ZipCrypto，但中文文件名可能乱码）
        // 无密码 → ZipExtractor（纯 Swift，GBK 文件名自动识别）
        if password != nil || isZipEncrypted(at: sourceURL) {
            try extractWithSSZipArchive(sourceURL, destinationURL, password)
        } else {
            try ZipExtractor().extract(zipURL: sourceURL, to: destinationURL)
        }
    }

    private func extractWithSSZipArchive(_ sourceURL: URL, _ destinationURL: URL, _ password: String?) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)

        var error: NSError?
        let success = SSZipArchive.unzipFile(
            atPath: sourceURL.path,
            toDestination: destinationURL.path,
            preserveAttributes: true,
            overwrite: true,
            password: password,
            error: &error,
            delegate: nil
        )

        if !success {
            if let error {
                throw error
            }
            throw ArchiveError.extractionFailed
        }
    }
}
