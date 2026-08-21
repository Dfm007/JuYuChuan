import Foundation
import Compression

enum ZipExtractError: LocalizedError {
    case invalidArchive
    case compressionFailed
    case pathTraversal

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "压缩包格式无效"
        case .compressionFailed:
            return "解压失败"
        case .pathTraversal:
            return "压缩包含非法路径"
        }
    }
}

/// 纯 Swift 实现的无密码 zip 解压器。
/// 自行解析 zip 原始字节，文件名编码自动在 UTF-8 / GB18030 之间切换，
/// 解决 Windows 创建的 zip 中文文件名乱码问题。
/// 仅支持 Store(0) 与 Deflate(8) 两种无密码格式。
final class ZipExtractor {
    func extract(zipURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let data = try Data(contentsOf: zipURL)
        let bytes = [UInt8](data)

        guard let eocdOffset = findEOCD(in: bytes) else {
            throw ZipExtractError.invalidArchive
        }

        let entries = try parseCentralDirectory(bytes: bytes, eocdOffset: eocdOffset)

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        for entry in entries {
            let name = decodeFilename(entry.filenameBytes)
            guard !name.isEmpty else { continue }

            let destinationPath = destinationURL.appendingPathComponent(name)
            guard isPathSafe(destinationPath, root: destinationURL) else {
                throw ZipExtractError.pathTraversal
            }

            if entry.isDirectory {
                try fileManager.createDirectory(at: destinationPath, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let fileData = try extractEntryData(entry, zipBytes: bytes)
                try fileData.write(to: destinationPath)
            }
        }
    }

    // MARK: - 内部类型
    private struct ZipEntry {
        let filenameBytes: [UInt8]
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool {
            filenameBytes.last == 0x2F   // '/'
        }
    }

    // MARK: - EOCD 解析
    private func findEOCD(in bytes: [UInt8]) -> Int? {
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50,
               bytes[i + 1] == 0x4B,
               bytes[i + 2] == 0x05,
               bytes[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func parseCentralDirectory(bytes: [UInt8], eocdOffset: Int) throws -> [ZipEntry] {
        let entryCount = Int(readUInt16(bytes, eocdOffset + 10))
        let centralDirectoryOffset = Int(readUInt32(bytes, eocdOffset + 16))

        var entries: [ZipEntry] = []
        var cursor = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count else { break }

            // 检查中央目录文件头签名 0x02014b50 → 50 4B 01 02
            guard bytes[cursor] == 0x50,
                  bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01,
                  bytes[cursor + 3] == 0x02 else {
                throw ZipExtractError.invalidArchive
            }

            let compressionMethod = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let filenameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))

            guard cursor + 46 + filenameLength <= bytes.count else {
                throw ZipExtractError.invalidArchive
            }

            let filenameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + filenameLength)])

            entries.append(ZipEntry(
                filenameBytes: filenameBytes,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            cursor += 46 + filenameLength + extraLength + commentLength
        }

        return entries
    }

    // MARK: - 数据解压
    private func extractEntryData(_ entry: ZipEntry, zipBytes: [UInt8]) throws -> Data {
        let localOffset = entry.localHeaderOffset

        guard localOffset + 30 <= zipBytes.count,
              zipBytes[localOffset] == 0x50,
              zipBytes[localOffset + 1] == 0x4B,
              zipBytes[localOffset + 2] == 0x03,
              zipBytes[localOffset + 3] == 0x04 else {
            throw ZipExtractError.invalidArchive
        }

        let filenameLength = Int(readUInt16(zipBytes, localOffset + 26))
        let extraLength = Int(readUInt16(zipBytes, localOffset + 28))
        let dataStart = localOffset + 30 + filenameLength + extraLength

        guard dataStart + entry.compressedSize <= zipBytes.count else {
            throw ZipExtractError.invalidArchive
        }

        let compressedData = Array(zipBytes[dataStart..<(dataStart + entry.compressedSize)])

        switch entry.compressionMethod {
        case 0:  // Store
            return Data(compressedData)
        case 8:  // Deflate
            return try inflate(compressedData, expectedSize: entry.uncompressedSize)
        default:
            throw ZipExtractError.compressionFailed
        }
    }

    private func inflate(_ compressed: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        var output = [UInt8](repeating: 0, count: expectedSize)

        let decodedSize = output.withUnsafeMutableBytes { dst -> Int in
            compressed.withUnsafeBufferPointer { src -> Int in
                let srcPtr = src.baseAddress!
                let dstPtr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return compression_decode_buffer(
                    dstPtr,
                    expectedSize,
                    srcPtr,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize > 0 else {
            throw ZipExtractError.compressionFailed
        }

        return Data(output[0..<decodedSize])
    }

    // MARK: - 编码识别
    private func decodeFilename(_ bytes: [UInt8]) -> String {
        // UTF-8 合法则直接使用
        if let utf8 = String(bytes: bytes, encoding: .utf8) {
            return utf8
        }

        // 否则按 GB18030（向下兼容 GBK / GB2312）解码
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let gb = String(bytes: bytes, encoding: gbEncoding) {
            return gb
        }

        // 兜底
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - 二进制读取（小端）
    private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // MARK: - 路径安全
    private func isPathSafe(_ path: URL, root: URL) -> Bool {
        let standardizedPath = path.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        return standardizedPath.path.hasPrefix(standardizedRoot.path)
    }
}
