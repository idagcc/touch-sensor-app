import Foundation
import Darwin

/// Keeps partial lines between reads. Oversized frames are discarded in full.
public struct CommandFramer {
    private var buffer: [UInt8] = []
    private var discarding = false
    public var mode: String
    public init(mode: String = "newline") { self.mode = mode }

    public mutating func feed(_ bytes: [UInt8]) -> [String] {
        var frames: [String] = []
        for byte in bytes {
            if mode == "byte" {
                if byte > 32, byte < 127 { frames.append(String(UnicodeScalar(byte))) }
            } else if byte == 10 || byte == 13 {
                if !discarding, let value = String(bytes: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                    frames.append(value)
                }
                buffer.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if buffer.count < 256 { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return frames
    }
}

public final class CommandRouter {
    private var lastCommand: String?
    private var lastTime: UInt64 = 0
    public init() {}
    public func route(_ command: String, configuration: Configuration, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> PlayerAction? {
        guard let action = configuration.commands[command] else { return nil }
        if command == lastCommand, now >= lastTime, now - lastTime < UInt64(configuration.serial.debounceMs) * 1_000_000 { return nil }
        lastCommand = command
        lastTime = now
        return action
    }
    public func reset() { lastCommand = nil; lastTime = 0 }
}

public final class SerialTransport {
    public static let supportedBaudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400]
    public var onCommand: ((String) -> Void)?
    public var onStatus: ((Bool, String) -> Void)?
    private let queue = DispatchQueue(label: "app.touchplayer.serial.io")
    private let callbackQueue: DispatchQueue
    private var source: DispatchSourceRead?
    private var closing = false
    private var activeFD: Int32 = -1
    private var closeCompletions: [() -> Void] = []
    private var pendingOpen: (path: String, baud: Int, framing: String)?
    private var closeMessage = "Disconnected"
    private var generation = 0
    private var framer = CommandFramer()
    private var frames: [String] = []
    private var deliveryScheduled = false
    private var deliveryEpoch = 0

    /// Descriptor reads, cancellation and ownership are confined to queue.
    /// Callbacks default to main; a supervisor may supply its own serial queue.
    public init(callbackQueue: DispatchQueue = .main) { self.callbackQueue = callbackQueue }
    deinit { source?.cancel() }

    public static func ports() -> [String] { SerialDeviceCatalog.devices().map(\.path) }

    public func connect(path: String, baudRate: Int, framing: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.clearPendingInput()
            guard Self.supportedBaudRates.contains(baudRate), ["newline", "byte"].contains(framing) else {
                self.pendingOpen = nil
                self.closeMessage = "Invalid serial settings"
                self.pump()
                return
            }
            self.pendingOpen = (path, baudRate, framing)
            self.pump()
        }
    }

    public func disconnect(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.pendingOpen = nil
            self.closeMessage = "Disconnected"
            if let completion { self.closeCompletions.append(completion) }
            self.clearPendingInput()
            self.pump()
        }
    }

    /// Used once after the board's startup window, never during normal idle time.
    public func discardInput(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearPendingInput()
            if self.activeFD >= 0, tcflush(self.activeFD, TCIFLUSH) != 0 {
                self.fail("Could not clear Arduino startup input")
                return
            }
            self.callbackQueue.async(execute: completion)
        }
    }

    private func clearPendingInput() {
        framer = CommandFramer(mode: framer.mode)
        frames.removeAll(keepingCapacity: true)
        deliveryEpoch += 1
        deliveryScheduled = false
    }

    private func pump() {
        guard !closing else { return }
        if let active = source {
            closing = true
            source = nil
            activeFD = -1
            // The cancel handler owns close(fd) and calls pump only AFTER close.
            // A rapid connect/disconnect/connect cannot reopen an old locked port.
            active.cancel()
            return
        }
        let completions = closeCompletions
        closeCompletions.removeAll()
        if !completions.isEmpty { callbackQueue.async { completions.forEach { $0() } } }
        guard let request = pendingOpen else {
            report(false, closeMessage, token: generation)
            return
        }
        pendingOpen = nil
        open(request)
    }

    private func open(_ request: (path: String, baud: Int, framing: String)) {
        let token = generation
        framer = CommandFramer(mode: request.framing)
        let fd = Darwin.open(request.path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { report(false, "Cannot open \(request.path): \(String(cString: strerror(errno)))", token: token); return }
        func reject(_ prefix: String) {
            let detail = String(cString: strerror(errno))
            _ = ioctl(fd, TIOCNXCL)
            Darwin.close(fd)
            report(false, "\(prefix): \(detail)", token: token)
        }
        guard ioctl(fd, TIOCEXCL) == 0 else { reject("Serial port is busy"); return }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { reject("Cannot read serial settings"); return }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CSIZE | CRTSCTS)
        options.c_cflag |= tcflag_t(CS8)
        guard cfsetispeed(&options, speed_t(request.baud)) == 0,
              cfsetospeed(&options, speed_t(request.baud)) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0 else { reject("Cannot configure serial port"); return }
        guard tcflush(fd, TCIFLUSH) == 0 else { reject("Cannot clear serial input"); return }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.readAvailable(fd: fd, token: token) }
        reader.setCancelHandler { [weak self] in
            _ = ioctl(fd, TIOCNXCL)
            Darwin.close(fd)
            guard let self else { return }
            self.closing = false
            self.pump()
        }
        source = reader
        activeFD = fd
        reader.resume()
        report(true, "Port open · \(request.path) · \(request.baud) baud", token: token)
    }

    private func readAvailable(fd: Int32, token: Int) {
        guard generation == token else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Drain bursts, but yield regularly so stop/reconnect requests cannot starve.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                let incoming = framer.feed(Array(bytes.prefix(count)))
                guard frames.count + incoming.count <= 512 else {
                    fail("Serial input overflow · check that the Arduino sends once per gesture")
                    return
                }
                frames.append(contentsOf: incoming)
                scheduleDelivery()
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { fail("Serial device disconnected"); return }
        }
    }

    private func fail(_ message: String) {
        generation += 1
        pendingOpen = nil
        closeMessage = message
        clearPendingInput()
        pump()
    }

    private func scheduleDelivery() {
        guard !frames.isEmpty, !deliveryScheduled else { return }
        deliveryScheduled = true
        let token = generation
        let epoch = deliveryEpoch
        callbackQueue.async { [weak self] in
            guard let self else { return }
            let batch: [String] = self.queue.sync {
                guard self.generation == token, self.deliveryEpoch == epoch else { return [] }
                let batch = Array(self.frames.prefix(64))
                self.frames.removeFirst(batch.count)
                self.deliveryScheduled = false
                return batch
            }
            for frame in batch {
                guard self.queue.sync(execute: { self.generation == token && self.deliveryEpoch == epoch }) else { break }
                self.onCommand?(frame)
            }
            self.queue.async { [weak self] in self?.scheduleDelivery() }
        }
    }

    private func report(_ connected: Bool, _ message: String, token: Int) {
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == token }) else { return }
            self.onStatus?(connected, message)
        }
    }
}
