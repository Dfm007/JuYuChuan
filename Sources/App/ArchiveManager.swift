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
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)

        var error: NSError?
        let success = SSZipArchive.unzipFile(
            atPath: sourceURL.path,
            toDestination: destinationURL.path,
            overwrite: true,
            password: password,
            error: &error
        )

        if !success {
            if let error {
                throw error
            }
            throw ArchiveError.extractionFailed
        }
    }
}
