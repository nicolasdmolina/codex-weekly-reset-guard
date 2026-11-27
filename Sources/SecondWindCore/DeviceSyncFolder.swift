import Foundation

/// The shared folder layout: `devices/<deviceID>.json` and `commands/<target>/<commandID>.json`.
/// Every read and write is coordinated so iCloud Drive never sees a half-written file. Files
/// synced from another Mac keep that Mac's permissions, so this does not use the private-file
/// checks that local state requires; it only refuses links, oversized files and bad JSON.
/// A missing folder or file reads as empty. Any other failure to list or read throws, so a Mac
/// that cannot see the folder reports it instead of looking synced.
public struct DeviceSyncFolder: Sendable {
    public static let maximumFileBytes = 256 * 1_024

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, present only while iCloud Drive is on.
    public static func iCloudDriveDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// The Second Wind folder in iCloud Drive, or nil when iCloud Drive is off on this Mac.
    public static func iCloud(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DeviceSyncFolder? {
        let drive = iCloudDriveDirectory(home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return DeviceSyncFolder(root: drive.appendingPathComponent("Second Wind", isDirectory: true))
    }

    var devicesDirectory: URL { root.appendingPathComponent("devices", isDirectory: true) }

    func commandsDirectory(for device: SyncDeviceID) -> URL {
        root.appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent(device.description, isDirectory: true)
    }

    func snapshotURL(for device: SyncDeviceID) -> URL {
        devicesDirectory.appendingPathComponent("\(device).json", isDirectory: false)
    }

    // MARK: Snapshots

    public func publish(_ snapshot: DeviceSnapshot) throws {
        try write(snapshot, to: snapshotURL(for: snapshot.deviceID))
    }

    /// Every other device's readable snapshot. A file must be named for the device it describes.
    public func readSnapshots(excluding device: SyncDeviceID) throws -> [DeviceSnapshot] {
        try files(in: devicesDirectory).compactMap { url -> DeviceSnapshot? in
            guard url.pathExtension == "json",
                  let named = SyncDeviceID(string: url.deletingPathExtension().lastPathComponent),
                  named != device,
                  case let .value(snapshot)? = try read(DeviceSnapshot.self, at: url),
                  snapshot.deviceID == named,
                  snapshot.schemaVersion <= DeviceSnapshot.currentSchemaVersion
            else { return nil }
            return snapshot
        }
        .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    public func removeSnapshot(for device: SyncDeviceID) throws {
        try delete(snapshotURL(for: device))
    }

    // MARK: Commands

    /// Creates this device's command folder ahead of time, so a sender writes into a folder
    /// iCloud Drive has already synced instead of creating a new one.
    public func prepareInbox(for device: SyncDeviceID) throws {
        try FileManager.default.createDirectory(at: commandsDirectory(for: device), withIntermediateDirectories: true)
    }

    public func send(_ command: RemoteCommand, to device: SyncDeviceID) throws {
        let url = commandsDirectory(for: device)
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json", isDirectory: false)
        try write(command, to: url)
    }

    /// Command files addressed to `device`, each with its command or nil when the file is not a
    /// valid command. A file that vanished between listing and reading is left out.
    public func commands(for device: SyncDeviceID) throws -> [(url: URL, command: RemoteCommand?)] {
        try files(in: commandsDirectory(for: device))
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                switch try read(RemoteCommand.self, at: url) {
                case nil:
                    return nil
                case .invalid:
                    return (url, nil)
                case let .value(command):
                    // A command whose name and id disagree was not written by Second Wind.
                    let named = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                    return (url, command.id == named ? command : nil)
                }
            }
    }

    public func delete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
            } catch {
                deleteError = error
            }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }

    // MARK: Files

    /// Regular files in `directory`. A `.name.icloud` placeholder starts its download and is
    /// read on a later pass.
    private func files(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var entries: [URL] = []
        var listError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: directory,
            options: [],
            error: &coordinationError
        ) { directory in
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: []
                )
            } catch {
                listError = error
            }
        }
        if let error = coordinationError ?? listError {
            if Self.isMissing(error) { return [] }
            throw error
        }
        var result: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: directory.appendingPathComponent(realName, isDirectory: false)
                )
                continue
            }
            guard !name.hasPrefix("."),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            result.append(url)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private enum ReadResult<Value> {
        case value(Value)
        /// Readable but too large or not the expected JSON.
        case invalid
    }

    /// nil when the file is gone; throws when it exists but cannot be read.
    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> ReadResult<Value>? {
        var data: Data?
        var tooLarge = false
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { url in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maximumFileBytes else {
                    tooLarge = true
                    return
                }
                data = try Data(contentsOf: url)
            } catch {
                readError = error
            }
        }
        if let error = coordinationError ?? readError {
            if Self.isMissing(error) { return nil }
            throw error
        }
        guard !tooLarge, let data, data.count <= Self.maximumFileBytes,
              let value = try? Self.decoder.decode(Value.self, from: data)
        else { return .invalid }
        return .value(value)
    }

    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain:
            return error.code == Int(ENOENT)
        default:
            return false
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        guard data.count <= Self.maximumFileBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
