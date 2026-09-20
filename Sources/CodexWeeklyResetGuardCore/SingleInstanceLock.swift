import Darwin
import Foundation

public final class SingleInstanceLock: @unchecked Sendable {
    private let descriptor: Int32
    public let url: URL

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        try PrivateFileIO.ensurePrivateDirectory(self.url.deletingLastPathComponent())

        let descriptor = open(
            self.url.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var shouldClose = true
        defer {
            if shouldClose { close(descriptor) }
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EFTYPE)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            throw SingleInstanceError.alreadyRunning(
                POSIXError(POSIXErrorCode(rawValue: code) ?? .EWOULDBLOCK)
            )
        }

        let pidText = "\(getpid())\n"
        guard ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array(pidText.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptor = descriptor
        shouldClose = false
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum SingleInstanceError: LocalizedError {
    case alreadyRunning(Error)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Codex Weekly Reset Guard is already running."
        }
    }
}
