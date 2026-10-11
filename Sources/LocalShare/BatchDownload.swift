import Foundation

// Store regular files in a UTF-8 ZIP64 archive without buffering their contents in memory.
// The response retains this object until streaming ends, including a disconnected client.
final class BatchDownload {
    private let directory: URL
    let url: URL

    init(paths: [String], share: FileServer.Share) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShare-\(UUID().uuidString)")
        url = directory.appendingPathComponent("LocalShare.zip")
        let fm = FileManager.default
        var files: [(name: String, url: URL)] = []
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var names = Set<String>()
            for path in paths {
                guard let decoded = path.removingPercentEncoding,
                      let source = share.fileURL(for: decoded),
                      try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let name = (decoded as NSString).lastPathComponent
                guard name != ".", name != "..", !name.isEmpty, names.insert(name).inserted else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                files.append((name, source))
            }
            try Self.writeZIP(files, to: url)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    // Format: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT (4.3, 4.5.3, Appendix D).
    // ZIP64 sizes and offsets are used even for small files; bit 11 preserves Unicode names
    // across macOS, Windows and mobile unzip tools. Stored entries avoid recompressing media.
    private static func writeZIP(_ files: [(name: String, url: URL)], to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            guard name.count <= Int(UInt16.max) else { throw CocoaError(.fileWriteInvalidFileName) }
            let offset = try output.offset()
            var local = ZIPBytes()
            local.u32(0x04034b50); local.u16(45); local.u16(0x0808); local.u16(0)
            local.u16(0); local.u16(33); local.u32(0)
            local.u32(.max); local.u32(.max); local.u16(UInt16(name.count)); local.u16(20)
            local.data.append(name)
            local.u16(1); local.u16(16); local.u64(0); local.u64(0)
            try output.write(contentsOf: local.data)
            let input = try FileHandle(forReadingFrom: file.url)
            var size: UInt64 = 0, crc: UInt32 = .max
            do {
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                    for byte in chunk { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
                    try output.write(contentsOf: chunk)
                    size += UInt64(chunk.count)
                }
            }
            crc ^= .max
            var descriptor = ZIPBytes()
            descriptor.u32(0x08074b50); descriptor.u32(crc); descriptor.u64(size); descriptor.u64(size)
            try output.write(contentsOf: descriptor.data)
            var entry = ZIPBytes()
            entry.u32(0x02014b50); entry.u16(45); entry.u16(45); entry.u16(0x0808); entry.u16(0)
            entry.u16(0); entry.u16(33); entry.u32(crc); entry.u32(.max); entry.u32(.max)
            entry.u16(UInt16(name.count)); entry.u16(28); entry.u16(0); entry.u16(0); entry.u16(0)
            entry.u32(0); entry.u32(.max); entry.data.append(name)
            entry.u16(1); entry.u16(24); entry.u64(size); entry.u64(size); entry.u64(offset)
            directory.append(entry.data)
        }
        let directoryOffset = try output.offset()
        try output.write(contentsOf: directory)
        let endOffset = try output.offset()
        var end = ZIPBytes()
        end.u32(0x06064b50); end.u64(44); end.u16(45); end.u16(45); end.u32(0); end.u32(0)
        end.u64(UInt64(files.count)); end.u64(UInt64(files.count)); end.u64(UInt64(directory.count)); end.u64(directoryOffset)
        end.u32(0x07064b50); end.u32(0); end.u64(endOffset); end.u32(1)
        end.u32(0x06054b50); end.u16(0); end.u16(0); end.u16(.max); end.u16(.max)
        end.u32(.max); end.u32(.max); end.u16(0)
        try output.write(contentsOf: end.data)
    }
}

private struct ZIPBytes {
    var data = Data()
    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func u64(_ value: UInt64) { append(value) }
    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
