import Flutter
import NetworkExtension

@MainActor
final class VPNService {
    private let channel: FlutterMethodChannel
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var polling = false
    private var revision = 0
    private var transition: Task<Void, Never>?

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.follow.clash/service", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else { return }
                do { result(try await self.handle(call)) }
                catch { result(FlutterError(code: "ios_service", message: error.localizedDescription, details: nil)) }
            }
        }
        CoreBridge.shared.onEvent = { [weak self] data in
            Task { @MainActor in
                guard let self, self.manager?.connection.status != .connected else { return }
                self.channel.invokeMethod("event", arguments: String(data: data, encoding: .utf8))
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.publishStatus() }
        }
    }

    private var startedAt: Int64 {
        guard let connection = manager?.connection, connection.status == .connected,
              let date = connection.connectedDate else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func publishStatus() {
        let status = manager?.connection.status
        if status == .connecting || status == .disconnecting || status == .reasserting { return }
        channel.invokeMethod("statusChanged", arguments: startedAt)
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let identifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let selected = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier }
            ?? NETunnelProviderManager()
        manager = selected
        return selected
    }

    private func setRunning(_ running: Bool) async throws -> Bool {
        revision += 1
        let request = revision
        let previous = transition
        let work = Task { @MainActor () throws -> Bool in
            await previous?.value
            guard self.revision == request else { throw CoreError.message("VPN request superseded") }
            let manager = try await self.loadManager()
            if running {
                if manager.connection.status == .connected { return true }
                try await SharedStore.snapshot()
                guard self.revision == request else { throw CoreError.message("VPN request superseded") }
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = Bundle.main.bundleIdentifier! + ".PacketTunnel"
                configuration.serverAddress = "FlClash"
                configuration.disconnectOnSleep = false
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "FlClash"
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                guard self.revision == request else { throw CoreError.message("VPN request superseded") }
                try manager.connection.startVPNTunnel()
            } else {
                manager.connection.stopVPNTunnel()
            }
            for _ in 0..<300 {
                guard self.revision == request else {
                    if running { manager.connection.stopVPNTunnel() }
                    throw CoreError.message("VPN request superseded")
                }
                let status = manager.connection.status
                if running && status == .connected || !running && (status == .disconnected || status == .invalid) {
                    self.publishStatus()
                    return true
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if running { manager.connection.stopVPNTunnel() }
            self.publishStatus()
            throw CoreError.message("VPN transition timed out. Check the PacketTunnel device log.")
        }
        transition = Task { _ = try? await work.value }
        return try await work.value
    }

    private func send(_ data: Data) async throws -> Data {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { throw CoreError.message("VPN is not connected") }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ProviderReply(continuation)
            do {
                try session.sendProviderMessage(data) { reply.finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 180) { reply.finish(nil) }
            } catch { reply.finish(nil) }
        }
    }

    private func pollEvents() async {
        guard !polling, manager?.connection.status == .connected else { return }
        polling = true
        defer { polling = false }
        if let data = try? await send(Data("events".utf8)) {
            channel.invokeMethod("event", arguments: String(data: data, encoding: .utf8))
        }
    }

    private func handle(_ call: FlutterMethodCall) async throws -> Any? {
        switch call.method {
        case "homeDirectory": return try SharedStore.directory("home").path
        case "init":
            _ = try await loadManager()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.pollEvents() }
                }
            }
            return ""
        case "shutdown":
            timer?.invalidate()
            timer = nil
            return true
        case "getRunTime":
            _ = try await loadManager()
            return startedAt
        case "syncState":
            guard let string = call.arguments as? String,
                  let value = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
                throw CoreError.message("Invalid shared state")
            }
            var merged = (try? SharedStore.read("state.json")) ?? [:]
            for (key, value) in value where !(value is NSNull) { merged[key] = value }
            try SharedStore.write(merged, to: "state.json")
            return ""
        case "start": return try await setRunning(true)
        case "stop": return try await setRunning(false)
        case "invokeMethod":
            guard let string = call.arguments as? String else { throw CoreError.message("Invalid Core request") }
            let data = Data(string.utf8)
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let method = request["method"] as? String ?? ""
            if method == "initClash", let arguments = request["arguments"] as? [String: Any] {
                try SharedStore.write(arguments, to: "init.json")
            }
            if method == "setupConfig", let arguments = request["arguments"] as? [String: Any] {
                var state = (try? SharedStore.read("state.json")) ?? [:]
                state["setupParams"] = arguments
                try SharedStore.write(state, to: "state.json")
            }
            let hostMethods = ["initClash", "getIsInit", "validateConfig", "getConfig", "clearEffect"]
            let response: Data
            let status = manager?.connection.status ?? .disconnected
            if hostMethods.contains(method) || status == .disconnected || status == .invalid {
                response = try await CoreBridge.shared.invoke(data)
            } else {
                guard status == .connected else { throw CoreError.message("VPN is changing state. Retry after it connects.") }
                if method == "setupConfig" { try await SharedStore.snapshot() }
                response = try await send(data)
            }
            return String(data: response, encoding: .utf8)
        default: return FlutterMethodNotImplemented
        }
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

private final class ProviderReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let data { pending?.resume(returning: data) }
        else { pending?.resume(throwing: CoreError.message("VPN Core did not respond")) }
    }
}
