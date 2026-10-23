import Foundation

enum SharedStore {
    private static let snapshotQueue = DispatchQueue(label: "com.follow.clash.snapshot", qos: .utility)
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "FlClashAppGroup") as? String ?? "" }
    static var root: URL {
        get throws {
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw CoreError.message("App Group is unavailable. Check signing for both iOS targets.")
            }
            return root
        }
    }

    static func directory(_ name: String) throws -> URL {
        let url = try root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
        return url
    }

    static func read(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.message("Invalid shared configuration: \(name)")
        }
        return value
    }

    static func write(_ value: [String: Any], to name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func snapshot() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            snapshotQueue.async {
                do { try makeSnapshot(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func makeSnapshot() throws {
        let source = try directory("home")
        let target = try directory("runtime")
        let fm = FileManager.default
        for name in ["GEOIP.metadb", "GEOIP.dat", "GEOSITE.dat", "ASN.mmdb", "profiles"] {
            let origin = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: origin.path) else { continue }
            if try origin.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
               let files = fm.enumerator(at: origin, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let file as URL in files {
                    if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
                    let relative = String(file.path.dropFirst(source.path.count + 1))
                    try copy(file, to: target.appendingPathComponent(relative))
                }
            } else {
                try copy(origin, to: target.appendingPathComponent(name))
            }
        }
        let config = try String(contentsOf: source.appendingPathComponent("config.yaml"), encoding: .utf8)
        let configuration = target.appendingPathComponent("config.yaml")
        try config.replacingOccurrences(of: source.path, with: target.path)
            .write(to: configuration, atomically: true, encoding: .utf8)
        try protect(configuration)
    }

    private static func copy(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let attributes = try source.resourceValues(forKeys: keys)
        if let existing = try? target.resourceValues(forKeys: keys),
           attributes.fileSize == existing.fileSize,
           attributes.contentModificationDate == existing.contentModificationDate { return }
        let staging = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
        try protect(target)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }
}
