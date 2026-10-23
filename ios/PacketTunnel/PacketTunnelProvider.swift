import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let packetLock = NSLock()
    private var generation = UUID()
    private var active = false
    private var startup: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var startReply: TunnelStartReply?
    private var stateEvents: [String: [String: Any]] = [:]
    private var delayEvents: [[String: Any]] = []
    private var bulkEvents: [[String: Any]] = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        packetLock.lock()
        generation = UUID()
        let session = generation
        packetLock.unlock()
        let reply = TunnelStartReply(completionHandler)
        startReply = reply
        let previousCleanup = cleanup
        CoreBridge.shared.onEvent = { [weak self] data in self?.enqueue(data) }
        startup = Task {
            do {
                await previousCleanup?.value
                try Task.checkCancellation()
                let home = try SharedStore.directory("runtime")
                let state = try SharedStore.read("state.json")
                let info = try SharedStore.read("init.json")
                _ = try await CoreBridge.shared.call("initClash", ["home-dir": home.path, "version": info["version"] ?? 0])
                try Task.checkCancellation()
                let error = try await CoreBridge.shared.call("setupConfig", state["setup-params"] ?? state["setupParams"] ?? [:])
                if let message = error as? String, !message.isEmpty { throw CoreError.message(message) }
                try Task.checkCancellation()
                let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
                settings.mtu = 1500
                let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
                ipv4.includedRoutes = [.default()]
                settings.ipv4Settings = ipv4
                let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
                ipv6.includedRoutes = [.default()]
                settings.ipv6Settings = ipv6
                settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])
                settings.dnsSettings?.matchDomains = [""]
                try await setTunnelNetworkSettings(settings)
                try Task.checkCancellation()
                CoreBridge.shared.setPacketHandler { [weak self] data in self?.writePacket(data, session: session) }
                guard flclash_start_tun() == 0 else { throw CoreError.message("Unable to start the packet stack") }
                try Task.checkCancellation()
                guard activate(session: session) else { throw CancellationError() }
                readPackets(session: session)
                reply.finish(nil)
            } catch {
                setActive(false)
                flclash_stop_tun()
                CoreBridge.shared.setPacketHandler(nil)
                reply.finish(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetLock.lock()
        active = false
        generation = UUID()
        packetLock.unlock()
        startup?.cancel()
        startReply?.finish(CancellationError())
        flclash_stop_tun()
        CoreBridge.shared.setPacketHandler(nil)
        let pendingStartup = startup
        cleanup = Task {
            await pendingStartup?.value
            _ = try? await CoreBridge.shared.call("shutdown")
        }
        completionHandler()
    }

    private func activate(session: UUID) -> Bool {
        packetLock.lock()
        defer { packetLock.unlock() }
        guard generation == session else { return false }
        active = true
        return true
    }

    private func setActive(_ value: Bool) {
        packetLock.lock()
        active = value
        packetLock.unlock()
    }

    private func writePacket(_ data: Data, session: UUID) {
        packetLock.lock()
        defer { packetLock.unlock() }
        guard active, generation == session, let first = data.first else { return }
        packetFlow.writePackets([data], withProtocols: [NSNumber(value: first >> 4 == 6 ? AF_INET6 : AF_INET)])
    }

    private func readPackets(session: UUID) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.packetLock.lock()
            let running = self.active && self.generation == session
            self.packetLock.unlock()
            guard running else { return }
            for data in packets {
                data.withUnsafeBytes { bytes in
                    _ = flclash_input_packet(UnsafeMutablePointer(mutating: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)), Int32(data.count))
                }
            }
            self.readPackets(session: session)
        }
    }

    private func enqueue(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = envelope["arguments"] as? [[String: Any]] else { return }
        for event in events {
            let type = event["type"] as? String ?? ""
            if type == "loaded" || type == "geoUpdate" {
                let identity = (event["data"] as? [String: Any])?["type"] as? String
                    ?? event["data"] as? String ?? ""
                stateEvents[type + ":" + identity] = event
            } else if type == "delay" {
                if delayEvents.count >= 256 { delayEvents.removeFirst() }
                delayEvents.append(event)
            } else {
                if bulkEvents.count >= 128 { bulkEvents.removeFirst() }
                bulkEvents.append(event)
            }
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if String(data: messageData, encoding: .utf8) == "events" {
            DispatchQueue.main.async {
                let stateKeys = Array(self.stateEvents.keys.prefix(32))
                let events = stateKeys.compactMap { self.stateEvents.removeValue(forKey: $0) }
                    + Array(self.delayEvents.prefix(16)) + Array(self.bulkEvents.prefix(16))
                self.delayEvents.removeFirst(min(16, self.delayEvents.count))
                self.bulkEvents.removeFirst(min(16, self.bulkEvents.count))
                completionHandler?(try? JSONSerialization.data(withJSONObject: ["method": "message", "arguments": events]))
            }
            return
        }
        Task {
            do { completionHandler?(try await CoreBridge.shared.invoke(messageData)) }
            catch { completionHandler?(nil) }
        }
    }
}

private final class TunnelStartReply {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    func finish(_ error: Error?) {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        pending?(error)
    }
}
