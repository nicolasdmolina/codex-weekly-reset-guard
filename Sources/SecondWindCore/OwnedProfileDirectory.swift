import Darwin
import Foundation

public enum OwnedProfileDirectoryError: Error, Equatable, Sendable {
    case rootNotDirectory(URL)
    case rootNotOwned(URL)
    case tooDeep
    case ioFailure(operation: String, code: Int32)
}

/// Discards an app-owned private profile folder (`<root>/<lowercased uuid>`).
///
/// The leaf name comes only from the profile UUID, never from persisted paths. The folder is
/// first renamed to `.discard-<uuid>` inside the same root so nothing can use it, then deleted
/// with descriptor-relative calls that never follow a symbolic link: a link found anywhere in the
/// tree is unlinked itself and its target is left alone. File contents are never opened.
public enum OwnedProfileDirectory {
    public static let discardPrefix = ".discard-"
    static let maximumDepth = 64

    /// Moves the profile folder aside. Returns false when there was nothing to move.
    @discardableResult
    public static func isolate(profileID: UUID, root: URL) throws -> Bool {
        guard let rootDescriptor = try openRoot(root) else { return false }
        defer { close(rootDescriptor) }
        let name = leafName(for: profileID)
        let isolated = discardName(for: profileID)
        // A leftover from an interrupted discard would make the rename fail.
        try removeTree(parent: rootDescriptor, name: isolated, depth: 0)
        switch try renameExclusive(rootDescriptor, from: name, to: isolated) {
        case .moved:
            break
        case .sourceMissing:
            return false
        case .destinationOccupied:
            throw OwnedProfileDirectoryError.ioFailure(operation: "rename-isolate", code: EEXIST)
        }
        try syncDirectory(rootDescriptor)
        return true
    }

    /// Puts an isolated folder back, for a removal whose state change did not commit.
    @discardableResult
    public static func restoreIsolated(profileID: UUID, root: URL) throws -> Bool {
        guard let rootDescriptor = try openRoot(root) else { return false }
        defer { close(rootDescriptor) }
        // If something already took the original name, the isolated copy stays staged for
        // `recoverInterruptedDiscards`.
        let result = try renameExclusive(
            rootDescriptor,
            from: discardName(for: profileID),
            to: leafName(for: profileID)
        )
        guard result == .moved else { return false }
        try syncDirectory(rootDescriptor)
        return true
    }

    /// True only when `<root>/<uuid>` is a real directory owned by this user, checked without
    /// following a link. Callers run a provider tool against the folder only when this holds.
    public static func isOwnedRealDirectory(profileID: UUID, root: URL) -> Bool {
        guard let rootDescriptor = try? openRoot(root) else { return false }
        defer { close(rootDescriptor) }
        var status = stat()
        guard fstatat(rootDescriptor, leafName(for: profileID), &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFDIR && status.st_uid == getuid()
    }

    /// Deletes an already isolated folder. Succeeds when it is already gone.
    public static func discardIsolated(profileID: UUID, root: URL) throws {
        guard let rootDescriptor = try openRoot(root) else { return }
        defer { close(rootDescriptor) }
        try removeTree(parent: rootDescriptor, name: discardName(for: profileID), depth: 0)
        try syncDirectory(rootDescriptor)
    }

    /// Isolates, then deletes, the profile folder. Succeeds when it is already gone.
    public static func discard(profileID: UUID, root: URL) throws {
        try isolate(profileID: profileID, root: root)
        try discardIsolated(profileID: profileID, root: root)
    }

    /// What `recoverInterruptedDiscards` did with each `.discard-<uuid>` entry, sorted by UUID.
    public struct Recovery: Equatable, Sendable {
        /// Still enrolled and the live path was free: moved back into place.
        public var restored: [UUID] = []
        /// Not enrolled, or not a real folder owned by this user: deleted without following links.
        public var discarded: [UUID] = []
        /// Still enrolled, but something already sits at the live path: left staged, untouched.
        public var retained: [UUID] = []

        public init(restored: [UUID] = [], discarded: [UUID] = [], retained: [UUID] = []) {
            self.restored = restored
            self.discarded = discarded
            self.retained = retained
        }

        public var isEmpty: Bool { restored.isEmpty && discarded.isEmpty && retained.isEmpty }
    }

    /// Finishes or undoes removals that stopped after their folder was moved aside.
    ///
    /// `enrolledIDs` must be the committed account list from a successful state load. A missing or
    /// unreadable state file is not an empty roster; skip this call in that case.
    /// - Staged folder of an account that is still enrolled: its removal never committed, so it is
    ///   moved back. If something already occupies the live path it is left staged, untouched.
    /// - Staged folder of an account that is gone: its removal committed, so it is deleted.
    /// - A staged entry that is not a real folder owned by this user is unlinked, never followed
    ///   or restored. Names other than `.discard-<lowercased uuid>` are never touched.
    /// Repeated calls are safe: each one only acts on what is still staged.
    @discardableResult
    public static func recoverInterruptedDiscards(root: URL, enrolledIDs: Set<UUID>) throws -> Recovery {
        var recovery = Recovery()
        guard let rootDescriptor = try openRoot(root) else { return recovery }
        defer { close(rootDescriptor) }
        let staged = try entryNames(inDirectory: rootDescriptor).filter(isDiscardName).sorted()
        var changed = false
        for name in staged {
            guard let profileID = UUID(uuidString: String(name.dropFirst(discardPrefix.count))) else {
                continue
            }
            var status = stat()
            guard fstatat(rootDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError("lstat-staged")
            }
            let isOwnedFolder = status.st_mode & S_IFMT == S_IFDIR && status.st_uid == getuid()
            guard enrolledIDs.contains(profileID), isOwnedFolder else {
                try removeTree(parent: rootDescriptor, name: name, depth: 0)
                recovery.discarded.append(profileID)
                changed = true
                continue
            }
            switch try renameExclusive(rootDescriptor, from: name, to: leafName(for: profileID)) {
            case .moved:
                recovery.restored.append(profileID)
                changed = true
            case .destinationOccupied:
                recovery.retained.append(profileID)
            case .sourceMissing:
                continue
            }
        }
        if changed { try syncDirectory(rootDescriptor) }
        return recovery
    }

    private enum ExclusiveRename {
        case moved
        case destinationOccupied
        case sourceMissing
    }

    /// Renames within one directory without ever replacing an existing entry.
    private static func renameExclusive(
        _ directory: Int32,
        from source: String,
        to destination: String
    ) throws -> ExclusiveRename {
        guard renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL)) == 0 else {
            switch errno {
            case EEXIST: return .destinationOccupied
            case ENOENT: return .sourceMissing
            default: throw posixError("rename-exclusive")
            }
        }
        return .moved
    }

    static func leafName(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    static func discardName(for profileID: UUID) -> String {
        discardPrefix + leafName(for: profileID)
    }

    static func isDiscardName(_ name: String) -> Bool {
        guard name.hasPrefix(discardPrefix) else { return false }
        let suffix = String(name.dropFirst(discardPrefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }

    /// Opens the root without following a link at its last component. Intermediate components
    /// may be system links such as `/var -> /private/var`. A missing root means nothing to do.
    private static func openRoot(_ root: URL) throws -> Int32? {
        let path = root.standardizedFileURL.path
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP, ENOTDIR: throw OwnedProfileDirectoryError.rootNotDirectory(root)
            default: throw posixError("open-root")
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = posixError("fstat-root")
            close(descriptor)
            throw error
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw OwnedProfileDirectoryError.rootNotDirectory(root)
        }
        guard status.st_uid == getuid() else {
            close(descriptor)
            throw OwnedProfileDirectoryError.rootNotOwned(root)
        }
        return descriptor
    }

    private static func removeTree(parent: Int32, name: String, depth: Int) throws {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw posixError("lstat-entry")
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            try unlinkEntry(parent: parent, name: name, flags: 0)
            return
        }
        guard depth < maximumDepth else { throw OwnedProfileDirectoryError.tooDeep }

        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return
            // Replaced by a link or file after the check: remove that entry, never its target.
            case ELOOP, ENOTDIR: return try unlinkEntry(parent: parent, name: name, flags: 0)
            default: throw posixError("open-entry")
            }
        }
        defer { close(descriptor) }
        for child in try entryNames(inDirectory: descriptor) {
            try removeTree(parent: descriptor, name: child, depth: depth + 1)
        }
        try unlinkEntry(parent: parent, name: name, flags: AT_REMOVEDIR)
    }

    /// Lists a directory through a duplicate descriptor so the caller keeps its own open.
    private static func entryNames(inDirectory descriptor: Int32) throws -> [String] {
        let listing = dup(descriptor)
        guard listing >= 0 else { throw posixError("dup-directory") }
        guard let stream = fdopendir(listing) else {
            let error = posixError("open-listing")
            close(listing)
            throw error
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError("read-directory") }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func unlinkEntry(parent: Int32, name: String, flags: Int32) throws {
        guard unlinkat(parent, name, flags) == 0 || errno == ENOENT else {
            throw posixError(flags == AT_REMOVEDIR ? "remove-directory" : "unlink-entry")
        }
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw posixError("fsync-root") }
    }

    private static func posixError(_ operation: String) -> OwnedProfileDirectoryError {
        .ioFailure(operation: operation, code: errno)
    }
}
