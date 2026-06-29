import Foundation
import CryptoKit
import os.log

// MARK: - Storage Manager

actor StorageManager {
    private let metadata: TorrentMetadata
    private let baseDirectory: URL
    private var fileHandles: [String: FileHandle] = [:]
    private let logger = Logger(subsystem: "com.bitflow.engine", category: "Storage")

    // Disk cache for unwritten blocks
    private var pendingWrites: [Int: Data] = [:]
    private let maxCacheSize = 32 * 1024 * 1024  // 32 MB

    // Layout cache
    private let fileLayout: [(file: TorrentFileEntry, offset: Int64, length: Int64)]

    init(metadata: TorrentMetadata, directory: URL) {
        self.metadata = metadata
        self.baseDirectory = directory.appendingPathComponent(metadata.name, isDirectory: true)
        self.fileLayout = metadata.fileLayout()
    }

    // MARK: - Prepare (pre-allocate files)

    func prepare() async throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        for entry in metadata.files where !entry.paddingFile {
            let fileURL = fileURL(for: entry)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                // Pre-allocate space
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.truncate(atOffset: UInt64(entry.length))
                try handle.close()
            }
        }
        logger.info("Storage prepared for \(self.metadata.name)")
    }

    // MARK: - Write Piece

    func writePiece(index: Int, data: Data) async throws {
        let pieceOffset = Int64(index) * metadata.pieceLength
        let pieceSize = Int64(data.count)

        // Find which files this piece spans
        var dataOffset: Int64 = 0
        for (file, fileStart, fileLen) in fileLayout {
            guard !file.paddingFile else { continue }
            let fileEnd = fileStart + fileLen
            let pieceEnd = pieceOffset + pieceSize

            let overlapStart = max(pieceOffset, fileStart)
            let overlapEnd = min(pieceEnd, fileEnd)
            guard overlapEnd > overlapStart else { continue }

            let writeLength = overlapEnd - overlapStart
            let dataSliceStart = overlapStart - pieceOffset
            let fileWriteOffset = overlapStart - fileStart

            let slice = data[data.index(data.startIndex, offsetBy: Int(dataSliceStart))..<data.index(data.startIndex, offsetBy: Int(dataSliceStart + writeLength))]

            try writeToFile(file: file, offset: fileWriteOffset, data: Data(slice))
            dataOffset += writeLength
        }
    }

    private func writeToFile(file: TorrentFileEntry, offset: Int64, data: Data) throws {
        let url = fileURL(for: file)
        let handle = try getOrOpenHandle(for: url)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    // MARK: - Read Block (for uploading to peers)

    func readBlock(pieceIndex: Int, offset: Int, length: Int) async throws -> Data {
        let absoluteOffset = Int64(pieceIndex) * metadata.pieceLength + Int64(offset)
        var result = Data(capacity: length)
        var remaining = length
        var currentOffset = absoluteOffset

        for (file, fileStart, fileLen) in fileLayout {
            guard !file.paddingFile else { continue }
            guard remaining > 0 else { break }
            let fileEnd = fileStart + fileLen

            guard currentOffset < fileEnd && currentOffset + Int64(remaining) > fileStart else { continue }

            let readStart = max(currentOffset, fileStart)
            let readEnd = min(currentOffset + Int64(remaining), fileEnd)
            let readLen = readEnd - readStart
            let fileReadOffset = readStart - fileStart

            let url = fileURL(for: file)
            let handle = try getOrOpenHandle(for: url)
            try handle.seek(toOffset: UInt64(fileReadOffset))
            let chunk = try handle.read(upToCount: Int(readLen))
            result.append(chunk)
            currentOffset += readLen
            remaining -= Int(readLen)
        }

        return result
    }

    // MARK: - Verify (recheck)

    func verifyAllPieces(pieceManager: PieceManager) async -> Bitfield {
        var bitfield = Bitfield(size: metadata.pieceCount)

        for index in 0..<metadata.pieceCount {
            if let pieceData = try? await readPiece(index: index) {
                let hash = Data(Insecure.SHA1.hash(data: pieceData))
                if index < metadata.pieces.count && hash == metadata.pieces[index] {
                    bitfield[index] = true
                }
            }
        }

        logger.info("Verification complete: \(bitfield.completedCount)/\(self.metadata.pieceCount) pieces")
        return bitfield
    }

    func readPiece(index: Int) async throws -> Data {
        let pieceLen = Int(metadata.pieceSize(at: index))
        return try await readBlock(pieceIndex: index, offset: 0, length: pieceLen)
    }

    // MARK: - File Operations

    func deleteAllFiles() async throws {
        closeAllHandles()
        try FileManager.default.removeItem(at: baseDirectory)
    }

    func moveFiles(to destination: URL) async throws {
        closeAllHandles()
        try FileManager.default.moveItem(at: baseDirectory, to: destination.appendingPathComponent(metadata.name))
    }

    func diskUsage() async -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        return urls.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return acc + Int64(size)
        }
    }

    // MARK: - Private Helpers

    private func fileURL(for entry: TorrentFileEntry) -> URL {
        entry.path.reduce(baseDirectory) { $0.appendingPathComponent($1) }
    }

    private func getOrOpenHandle(for url: URL) throws -> FileHandle {
        let path = url.path
        if let existing = fileHandles[path] { return existing }
        let handle = try FileHandle(forUpdating: url)
        fileHandles[path] = handle
        return handle
    }

    private func closeAllHandles() {
        for handle in fileHandles.values { try? handle.close() }
        fileHandles.removeAll()
    }

    deinit {
        for handle in fileHandles.values { try? handle.close() }
    }
}
