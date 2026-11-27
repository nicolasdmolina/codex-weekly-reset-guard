import Foundation

/// The shared folder layout: `devices/<deviceID>.json` and `commands/<target>/<commandID>.json`.
/// Every read and write is coordinated so iCloud Drive never sees a half-written file. Files
/// synced from another Mac keep that Mac's permissions, so this does not use the private-file
/// checks that local state requires; it only refuses links, oversized files and bad JSON.
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
    public func readSnapshots(excluding device: SyncDeviceID) -> [DeviceSnapshot] {
        files(in: devicesDirectory).compactMap { url -> DeviceSnapshot? in
            guard url.pathExtension == "json",
                  let named = SyncDeviceID(string: url.deletingPathExtension().lastPathComponent),
                  named != device,
                  let snapshot = read(DeviceSnapshot.self, at: url),
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

    public func send(_ command: RemoteCommand, to device: SyncDeviceID) throws {
        let url = commandsDirectory(for: device)
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json", isDirectory: false)
        try write(command, to: url)
    }

    /// Command files addressed to `device`, each with its command or nil when it cannot be read.
    public func commands(for device: SyncDeviceID) -> [(url: URL, command: RemoteCommand?)] {
        files(in: commandsDirectory(for: device))
            .filter { $0.pathExtension == "json" }
            .map { url in
                let command = read(RemoteCommand.self, at: url)
                // A command whose name and id disagree was not written by Second Wind.
                return (url, command.flatMap { $0.id == UUID(uuidString: url.deletingPathExtension().lastPathComponent) ? $0 : nil })
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
    private func files(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }
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

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumFileBytes else { return }
            data = try? Data(contentsOf: url)
        }
        guard coordinationError == nil, let data, data.count <= Self.maximumFileBytes else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
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
