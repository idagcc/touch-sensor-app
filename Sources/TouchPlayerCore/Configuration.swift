import Foundation

public enum PlayerAction: String, Codable, CaseIterable {
    case play, toggle, pause, reset, restart, quit
}

public enum PlaybackState: String { case holding, playing, paused, finished }

public struct PlaybackMachine {
    public private(set) var state: PlaybackState = .holding
    public init() {}

    @discardableResult public mutating func apply(_ action: PlayerAction) -> PlaybackState {
        switch action {
        case .play: state = .playing
        case .toggle: state = state == .playing ? .paused : .playing
        case .pause: if state == .playing { state = .paused }
        case .reset: state = .holding
        case .restart: state = .playing
        case .quit: break
        }
        return state
    }

    public mutating func finish(returnToHolding: Bool) { state = returnToHolding ? .holding : .finished }
}

public struct Configuration: Codable, Equatable {
    public struct Serial: Codable, Equatable {
        public var port = ""
        public var baudRate = 9600
        public var autoConnect = true
        public var framing = "newline"
        public var debounceMs = 180
        public var deviceIdentity: SerialDeviceIdentity?
        public var startupDelayMs = 2000
        public var reconnectInitialDelayMs = 500
        public var reconnectMaxDelayMs = 10000
        // Disabled for existing firmware. Enable only when it sends HEARTBEAT.
        public var heartbeatTimeoutMs = 0
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case port, baudRate, autoConnect, framing, debounceMs, deviceIdentity
            case startupDelayMs, reconnectInitialDelayMs, reconnectMaxDelayMs, heartbeatTimeoutMs
        }
        public init(from decoder: Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            port = try values.decodeIfPresent(String.self, forKey: .port) ?? port
            baudRate = try values.decodeIfPresent(Int.self, forKey: .baudRate) ?? baudRate
            autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
            framing = try values.decodeIfPresent(String.self, forKey: .framing) ?? framing
            debounceMs = try values.decodeIfPresent(Int.self, forKey: .debounceMs) ?? debounceMs
            deviceIdentity = try values.decodeIfPresent(SerialDeviceIdentity.self, forKey: .deviceIdentity)
            startupDelayMs = try values.decodeIfPresent(Int.self, forKey: .startupDelayMs) ?? startupDelayMs
            reconnectInitialDelayMs = try values.decodeIfPresent(Int.self, forKey: .reconnectInitialDelayMs) ?? reconnectInitialDelayMs
            reconnectMaxDelayMs = try values.decodeIfPresent(Int.self, forKey: .reconnectMaxDelayMs) ?? reconnectMaxDelayMs
            heartbeatTimeoutMs = try values.decodeIfPresent(Int.self, forKey: .heartbeatTimeoutMs) ?? heartbeatTimeoutMs
        }
    }

    public struct Output: Codable, Equatable {
        public var width = 1920
        public var height = 1080
        public var displayID: UInt32 = 0
        public var scale = "fit"
        public var openOnLaunch = false
        public var fullscreenOnLaunch = false
        public init() {}
    }

    public struct Videos: Codable, Equatable {
        public var holdingFolder = "media/holding"
        public var playbackFolder = "media/playback"
        public var endBehavior = "holding"
        public var muteHolding = true
        public var volume = 1.0
        public init() {}
    }

    public var serial = Serial()
    public var output = Output()
    public var videos = Videos()
    public var commands: [String: PlayerAction] = ["0": .toggle, "1": .reset]
    public init() {}

    public func validate() throws {
        guard (1...16384).contains(output.width), (1...16384).contains(output.height) else {
            throw ConfigError.invalid("Width and height must be between 1 and 16384.")
        }
        guard ["fit", "fill", "stretch"].contains(output.scale) else {
            throw ConfigError.invalid("output.scale must be fit, fill, or stretch.")
        }
        guard ["holding", "freeze", "quit"].contains(videos.endBehavior) else {
            throw ConfigError.invalid("videos.endBehavior must be holding, freeze, or quit.")
        }
        guard ["newline", "byte"].contains(serial.framing) else {
            throw ConfigError.invalid("serial.framing must be newline or byte.")
        }
        guard SerialTransport.supportedBaudRates.contains(serial.baudRate) else {
            throw ConfigError.invalid("Unsupported baud rate: \(serial.baudRate).")
        }
        guard (0...10000).contains(serial.debounceMs), (0...1).contains(videos.volume), videos.volume.isFinite else {
            throw ConfigError.invalid("Debounce must be 0–10000 ms and volume must be 0–1.")
        }
        guard (0...30000).contains(serial.startupDelayMs),
              (100...60000).contains(serial.reconnectInitialDelayMs),
              (serial.reconnectInitialDelayMs...60000).contains(serial.reconnectMaxDelayMs),
              serial.heartbeatTimeoutMs == 0 || (250...600000).contains(serial.heartbeatTimeoutMs) else {
            throw ConfigError.invalid("Serial startup delay must be 0–30000 ms, retry delays 100–60000 ms (maximum ≥ initial), and heartbeat timeout 0 or 250–600000 ms.")
        }
        if let identity = serial.deviceIdentity {
            guard (0...65535).contains(identity.vendorID), (0...65535).contains(identity.productID),
                  identity.serialNumber?.isEmpty == false || identity.locationID != nil else {
                throw ConfigError.invalid("Device identity needs valid USB IDs and a serial number or USB location.")
            }
        }
        guard serial.framing == "newline" || serial.heartbeatTimeoutMs == 0 else {
            throw ConfigError.invalid("Heartbeat monitoring requires newline framing.")
        }
        guard !commands.isEmpty else { throw ConfigError.invalid("At least one serial command is required.") }
        for command in commands.keys {
            guard command != "READY", command != "HEARTBEAT" else {
                throw ConfigError.invalid("READY and HEARTBEAT are reserved serial status messages.")
            }
            guard !command.isEmpty, command == command.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.contains("\n"), !command.contains("\r"), command.utf8.count <= 256 else {
                throw ConfigError.invalid("Commands must be 1–256 bytes with no line breaks or surrounding spaces.")
            }
            if serial.framing == "byte", command.utf8.count != 1 {
                throw ConfigError.invalid("Byte framing requires single-byte commands.")
            }
        }
        guard !videos.holdingFolder.isEmpty, !videos.playbackFolder.isEmpty else {
            throw ConfigError.invalid("Both video folder paths are required.")
        }
    }
}

public enum ConfigError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public final class ConfigurationStore {
    public let root: URL
    public var file: URL { root.appendingPathComponent("config.json") }
    public init(root: URL) { self.root = root }

    public func load() throws -> Configuration {
        if !FileManager.default.fileExists(atPath: file.path) { try save(Configuration()) }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
        try config.validate()
        return config
    }

    public func save(_ config: Configuration) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: file, options: .atomic)
    }

    public func folder(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
    }

    public func media(in path: String) throws -> [URL] {
        let directory = folder(path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
