import Darwin
import Foundation

public actor SecureStateStore<Value: Codable & Sendable> {
    public nonisolated let fileURL: URL
    public nonisolated let maximumBytes: Int
    private let faultInjector: PrivateFileIOFaultInjector?

    public init(fileURL: URL, maximumBytes: Int = 8 * 1_024 * 1_024) {
        self.fileURL = fileURL.standardizedFileURL
        self.maximumBytes = maximumBytes
        self.faultInjector = nil
    }

    init(
        fileURL: URL,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        testingFaultInjector: PrivateFileIOFaultInjector
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.maximumBytes = maximumBytes
        self.faultInjector = testingFaultInjector
    }

    public func load() throws -> Value? {
        guard let data = try PrivateFileIO.readIfPresent(
            from: fileURL,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw SecureStateStoreError.fileTooLarge(data.count, maximumBytes: maximumBytes)
        }
        try PrivateFileIO.atomicWrite(data, to: fileURL, faultInjector: faultInjector)
    }

    /// Performs one serialized read-modify-write transaction.
    /// Separate `load` and `save` awaits can otherwise overwrite a concurrent update.
    @discardableResult
    public func update<Result: Sendable>(
        defaultValue: Value,
        _ transform: @Sendable (inout Value) throws -> Result
    ) throws -> Result {
        var value = try load() ?? defaultValue
        let result = try transform(&value)
        try save(value)
        return result
    }
}

public enum SecureStateStoreError: Error, Equatable, Sendable {
    case invalidParent(URL)
    case symbolicLink(URL)
    case notRegularFile(URL)
    case insecurePermissions(URL, mode: UInt16)
    case fileTooLarge(Int, maximumBytes: Int)
    case ioFailure(operation: String, code: Int32)
}

enum PrivateFileIO {
    static func ensurePrivateDirectory(_ directoryURL: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SecureStateStoreError.invalidParent(directoryURL)
            }
            let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SecureStateStoreError.symbolicLink(directoryURL)
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }

        guard chmod(directoryURL.path, mode_t(0o700)) == 0 else {
            throw posixError("chmod-directory")
        }
    }

    static func readIfPresent(from fileURL: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = openReadDescriptor(for: fileURL)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw SecureStateStoreError.symbolicLink(fileURL) }
            throw posixError("open-read")
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError("fstat")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SecureStateStoreError.notRegularFile(fileURL)
        }

        let permissions = UInt16(status.st_mode & 0o777)
        guard permissions & 0o077 == 0 else {
            throw SecureStateStoreError.insecurePermissions(fileURL, mode: permissions)
        }
        guard status.st_size <= maximumBytes else {
            throw SecureStateStoreError.fileTooLarge(
                Int(status.st_size),
                maximumBytes: maximumBytes
            )
        }

        var result = Data()
        result.reserveCapacity(max(0, Int(status.st_size)))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw SecureStateStoreError.fileTooLarge(
                    result.count,
                    maximumBytes: maximumBytes
                )
            }
        }
        return result
    }

    static func openReadDescriptor(for fileURL: URL) -> Int32 {
        open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func atomicWrite(
        _ data: Data,
        to fileURL: URL,
        faultInjector: PrivateFileIOFaultInjector? = nil
    ) throws {
        let directoryURL = fileURL.deletingLastPathComponent().standardizedFileURL
        try ensurePrivateDirectory(directoryURL)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw SecureStateStoreError.symbolicLink(fileURL)
            }
            guard values.isRegularFile == true else {
                throw SecureStateStoreError.notRegularFile(fileURL)
            }
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw posixError("open-write")
        }

        var shouldClose = true
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldClose { close(descriptor) }
            if shouldRemoveTemporaryFile { unlink(temporaryURL.path) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                offset += count
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw posixError("chmod-file")
        }
        try syncFileFully(descriptor, faultInjector: faultInjector)
        guard close(descriptor) == 0 else {
            shouldClose = false
            throw posixError("close")
        }
        shouldClose = false

        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw posixError("rename")
        }
        shouldRemoveTemporaryFile = false

        try faultInjector?.throwIfRequested(.openDirectory)
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw posixError("open-directory")
        }
        var shouldCloseDirectory = true
        defer {
            if shouldCloseDirectory { close(directoryDescriptor) }
        }

        try faultInjector?.throwIfRequested(.syncDirectory)
        guard fsync(directoryDescriptor) == 0 else {
            throw posixError("fsync-directory")
        }
        guard close(directoryDescriptor) == 0 else {
            shouldCloseDirectory = false
            throw posixError("close-directory")
        }
        shouldCloseDirectory = false
    }

    /// `F_FULLFSYNC` asks macOS to flush volatile drive caches as well as kernel buffers.
    /// Filesystems that explicitly do not support it fall back to `fsync`; genuine I/O errors
    /// remain fatal so a caller can never mistake an unproven write for a durable save.
    private static func syncFileFully(
        _ descriptor: Int32,
        faultInjector: PrivateFileIOFaultInjector?
    ) throws {
        try faultInjector?.throwIfRequested(.syncFile)

        #if os(macOS)
        if fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        let fullSyncError = errno
        guard fullSyncError == EINVAL || fullSyncError == ENOTSUP else {
            throw posixError("full-fsync-file", code: fullSyncError)
        }
        #endif

        guard fsync(descriptor) == 0 else {
            throw posixError("fsync-file")
        }
    }

    private static func posixError(
        _ operation: String,
        code: Int32? = nil
    ) -> SecureStateStoreError {
        .ioFailure(operation: operation, code: code ?? errno)
    }
}

enum PrivateFileIOFaultOperation: String, Sendable {
    case syncFile = "full-fsync-file"
    case openDirectory = "open-directory"
    case syncDirectory = "fsync-directory"
}

struct PrivateFileIOFaultInjector: Sendable {
    let operation: PrivateFileIOFaultOperation
    let code: Int32

    init(operation: PrivateFileIOFaultOperation, code: Int32 = EIO) {
        self.operation = operation
        self.code = code
    }

    func throwIfRequested(_ candidate: PrivateFileIOFaultOperation) throws {
        guard operation == candidate else { return }
        throw SecureStateStoreError.ioFailure(operation: candidate.rawValue, code: code)
    }
}
