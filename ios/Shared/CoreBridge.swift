import Foundation

final class CoreBridge {
    static let shared = CoreBridge()
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var eventHandler: ((Data) -> Void)?
    var onEvent: ((Data) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }
        set {
            lock.lock()
            eventHandler = newValue
            lock.unlock()
        }
    }
    private var packetHandler: ((Data) -> Void)?

    private init() {
        flclash_set_callbacks({ context, bytes, count in
            guard let context, let bytes else { return }
            CoreBridge.shared.finish(Int(bitPattern: context), .success(Data(bytes: bytes, count: Int(count))))
        }, { _, bytes, count in
            guard let bytes else { return }
            let data = Data(bytes: bytes, count: Int(count))
            DispatchQueue.main.async { CoreBridge.shared.onEvent?(data) }
        }, { _, bytes, count in
            guard let bytes else { return }
            let bridge = CoreBridge.shared
            bridge.lock.lock()
            let handler = bridge.packetHandler
            bridge.lock.unlock()
            handler?(Data(bytes: bytes, count: Int(count)))
        })
    }

    func setPacketHandler(_ handler: ((Data) -> Void)?) {
        lock.lock()
        packetHandler = handler
        lock.unlock()
    }

    private func finish(_ id: Int, _ result: Result<Data, Error>) {
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        callback?(result)
    }

    func invoke(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            nextID += 1
            let id = nextID
            pending[id] = { continuation.resume(with: $0) }
            lock.unlock()
            data.withUnsafeBytes { bytes in
                flclash_invoke(UnsafeMutableRawPointer(bitPattern: id),
                    UnsafeMutablePointer(mutating: bytes.baseAddress?.assumingMemoryBound(to: CChar.self)), Int32(data.count))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                self.finish(id, .failure(CoreError.message("Core request timed out")))
            }
        }
    }

    func call(_ method: String, _ arguments: Any = NSNull()) async throws -> Any {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
        let response = try await invoke(request)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw CoreError.message("Invalid Core response")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw CoreError.message(error["message"] as? String ?? "Core request failed")
        }
        return envelope["result"] ?? NSNull()
    }
}

enum CoreError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
