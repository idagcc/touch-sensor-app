import Foundation

public enum SerialConnectionPhase: String { case disconnected, waiting, connecting, settling, connected, suspended }

public struct SerialConnectionStatus {
    public var phase: SerialConnectionPhase
    public var message: String
    public var device: SerialDevice?
}

/// Persistent session policy. Discovery, boot timing, retries and liveness run
/// off the UI thread; the transport alone owns the actual serial descriptor.
public final class SerialConnection {
    public var onCommand: ((String) -> Void)?
    public var onStatus: ((SerialConnectionStatus) -> Void)?
    public var onDevicesChanged: (([SerialDevice]) -> Void)?
    private let queue = DispatchQueue(label: "app.touchplayer.serial.session")
    private let deviceProvider: () -> [SerialDevice]
    private let interval: DispatchTimeInterval
    private let gate = NSLock()
    private var epoch = 0
    private var callbacksStopped = false
    private var timer: DispatchSourceTimer?
    private var transport: SerialTransport?
    private var retiringTransports: [UUID: SerialTransport] = [:]
    private var settings = Configuration.Serial()
    private var devices: [SerialDevice] = []
    private var activeDevice: SerialDevice?
    private var desired = false
    private var suspended = false
    private var phase: SerialConnectionPhase = .disconnected
    private var backoff = SerialRetryBackoff()
    private var nextAttempt: UInt64 = 0
    private var readyAt: UInt64 = 0
    private var lastScan: UInt64 = 0
    private var lastHeartbeat: UInt64 = 0
    private var connectedSince: UInt64 = 0
    private var completingStartup = false
    private var frameWindow: UInt64 = 0
    private var frameCount = 0
    private var lastMessage = ""
    private var lastStatusEpoch = -1

    public init(deviceProvider: @escaping () -> [SerialDevice] = SerialDeviceCatalog.devices, pollInterval: DispatchTimeInterval = .milliseconds(250)) {
        self.deviceProvider = deviceProvider; self.interval = pollInterval
    }
    deinit { timer?.cancel() }

    public func configure(_ settings: Configuration.Serial) {
        queue.async { [weak self] in
            guard let self else { return }
            let previous = self.settings
            self.settings = settings
            self.ensureTimer()
            if settings.port.isEmpty, self.desired {
                self.desired = false
                self.retireTransport()
                self.emit(.disconnected, "Select an Arduino port first")
                return
            }
            let changed = previous.port != settings.port || previous.baudRate != settings.baudRate || previous.framing != settings.framing ||
                (previous.deviceIdentity != nil && previous.deviceIdentity != settings.deviceIdentity)
            if changed, self.desired {
                self.retireTransport()
                self.backoff.reset()
                self.nextAttempt = self.now
                self.emit(.waiting, "Serial settings changed · reconnecting")
                self.poll()
            } else if !settings.autoConnect, self.phase == .waiting {
                self.desired = false
                self.emit(.disconnected, "Automatic reconnection disabled")
            }
        }
    }

    public func start(settings: Configuration.Serial) {
        queue.async { [weak self] in
            guard let self else { return }
            self.retireTransport()
            self.settings = settings
            self.desired = !settings.port.isEmpty
            self.backoff.reset()
            self.nextAttempt = self.now
            self.ensureTimer()
            self.scanDevices(force: true)
            if self.desired {
                self.emit(.waiting, "Looking for selected Arduino")
                self.poll()
            } else { self.emit(.disconnected, "Select an Arduino port first") }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desired = false
            self.retireTransport()
            self.emit(.disconnected, "Disconnected by operator")
        }
    }

    public func refreshDevices() { queue.async { [weak self] in self?.scanDevices(force: true) } }

    public func suspend() {
        queue.async { [weak self] in
            guard let self, !self.suspended else { return }
            self.suspended = true
            self.retireTransport()
            if self.desired { self.emit(.suspended, "Mac sleeping · serial recovery will resume on wake") }
        }
    }

    public func resume() {
        queue.async { [weak self] in
            guard let self, self.suspended else { return }
            self.suspended = false
            self.scanDevices(force: true)
            if self.desired, self.settings.autoConnect {
                self.backoff.reset()
                self.nextAttempt = self.now + 1_000_000_000
                self.emit(.waiting, "Mac woke · waiting for USB device")
            } else {
                self.desired = false
                self.emit(.disconnected, "Mac woke · connect Arduino when ready")
            }
        }
    }

    public func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.desired = false
            self.retireTransport()
            self.gate.lock(); self.callbacksStopped = true; self.gate.unlock()
            self.timer?.cancel(); self.timer = nil
        }
    }

    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func advanceEpoch() { gate.lock(); epoch += 1; gate.unlock() }
    private func current(_ token: Int) -> Bool {
        gate.lock(); defer { gate.unlock() }
        return !callbacksStopped && epoch == token
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func scanDevices(force: Bool = false) {
        guard force || now - lastScan >= 1_000_000_000 else { return }
        lastScan = now
        let updated = deviceProvider()
        if force || updated != devices {
            devices = updated
            DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?(updated) }
        }
    }

    private func poll() {
        guard !suspended, !callbacksStopped else { return }
        scanDevices()
        guard desired else { return }
        if phase == .connected || phase == .settling {
            if let device = activeDevice, !FileManager.default.fileExists(atPath: device.path) {
                lost("Arduino unplugged")
                return
            }
            if phase == .settling, now >= readyAt { finishStartup() }
            if phase == .connected, settings.heartbeatTimeoutMs > 0,
               now - lastHeartbeat > UInt64(settings.heartbeatTimeoutMs) * 1_000_000 {
                lost("Arduino heartbeat timed out")
            }
            if phase == .connected, now - connectedSince >= 10_000_000_000 { backoff.reset() }
        } else if phase == .waiting, now >= nextAttempt {
            guard retiringTransports.isEmpty else { return }
            var selected = SerialDeviceCatalog.resolve(path: settings.port, identity: settings.deviceIdentity, devices: devices)
            // Exact-path fallback supports legacy drivers and test terminals. A
            // remembered USB identity must always be verified before opening.
            if selected == nil, settings.deviceIdentity == nil, FileManager.default.fileExists(atPath: settings.port) {
                selected = SerialDevice(path: settings.port)
            }
            guard let device = selected else {
                emit(.waiting, "Waiting for selected Arduino · reconnects automatically")
                nextAttempt = now + 500_000_000
                return
            }
            open(device)
        }
    }

    private func open(_ device: SerialDevice) {
        advanceEpoch()
        let token = epoch
        activeDevice = device
        completingStartup = false
        frameWindow = now; frameCount = 0
        let io = SerialTransport(callbackQueue: queue)
        io.onCommand = { [weak self] frame in
            guard let self, self.current(token) else { return }
            self.received(frame)
        }
        io.onStatus = { [weak self] opened, message in
            guard let self, self.current(token), self.desired else { return }
            if opened {
                self.readyAt = self.now + UInt64(self.settings.startupDelayMs) * 1_000_000
                self.emit(.settling, "Arduino starting · waiting for READY or \(self.settings.startupDelayMs) ms")
                if self.settings.startupDelayMs == 0 { self.finishStartup() }
            } else { self.lost(message) }
        }
        transport = io
        emit(.connecting, "Opening \(device.path)…")
        io.connect(path: device.path, baudRate: settings.baudRate, framing: settings.framing)
    }

    private func received(_ frame: String) {
        if now - frameWindow >= 1_000_000_000 { frameWindow = now; frameCount = 0 }
        frameCount += 1
        guard frameCount <= 100 else { lost("Serial message flood · check Arduino firmware"); return }
        if frame == "HEARTBEAT" { lastHeartbeat = now; return }
        if frame == "READY" {
            lastHeartbeat = now
            if phase == .settling { finishStartup() }
            return
        }
        guard phase == .connected else { return }
        let token = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token) else { return }
            self.onCommand?(frame)
        }
    }

    private func finishStartup() {
        guard !completingStartup, phase == .settling, let transport else { return }
        completingStartup = true
        let token = epoch
        transport.discardInput { [weak self] in
            guard let self, self.current(token), self.desired, !self.suspended else { return }
            self.completingStartup = false
            self.lastHeartbeat = self.now
            self.connectedSince = self.now
            if let device = self.activeDevice {
                self.settings.port = device.path
                self.settings.deviceIdentity = device.identity ?? self.settings.deviceIdentity
            }
            self.emit(.connected, "Connected · \(self.activeDevice?.path ?? self.settings.port) · \(self.settings.baudRate) baud")
        }
    }

    private func retireTransport() {
        advanceEpoch()
        if let io = transport {
            let id = UUID()
            retiringTransports[id] = io
            io.disconnect { [weak self] in
                guard let self else { return }
                self.retiringTransports.removeValue(forKey: id)
                self.poll()
            }
        }
        transport = nil
        activeDevice = nil
        completingStartup = false
    }

    private func lost(_ reason: String) {
        retireTransport()
        if desired, settings.autoConnect {
            let delay = backoff.nextDelayMs(initial: settings.reconnectInitialDelayMs, maximum: settings.reconnectMaxDelayMs)
            nextAttempt = now + UInt64(delay) * 1_000_000
            emit(.waiting, "\(reason) · retry in \(Double(delay)/1000) s")
        } else {
            desired = false
            emit(.disconnected, reason)
        }
    }

    private func emit(_ phase: SerialConnectionPhase, _ message: String) {
        guard self.phase != phase || lastMessage != message || lastStatusEpoch != epoch else { return }
        self.phase = phase; lastMessage = message
        lastStatusEpoch = epoch
        let status = SerialConnectionStatus(phase: phase, message: message, device: activeDevice)
        let token = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current(token) else { return }
            self.onStatus?(status)
        }
    }
}
