import XCTest
import Darwin
@testable import TouchPlayerCore

private final class TestTerminal {
    private(set) var master: Int32 = -1
    let path: String
    init() throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw POSIXError(.EIO) }
        self.master = master
        path = String(cString: name)
        close(slave)
    }
    func send(_ value: String) { _ = value.withCString { write(master, $0, value.utf8.count) } }
    func unplug() { if master >= 0 { close(master); master = -1 } }
    deinit { unplug() }
}

private final class TestDeviceList {
    private let lock = NSLock()
    private var storage: [SerialDevice] = []
    var devices: [SerialDevice] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

final class SerialReliabilityTests: XCTestCase {
    private func settings(_ terminal: TestTerminal) -> Configuration.Serial {
        var config = Configuration.Serial()
        config.port = terminal.path
        config.startupDelayMs = 0
        config.reconnectInitialDelayMs = 100
        config.reconnectMaxDelayMs = 400
        return config
    }

    func testOldJSONGetsCompatibleReliabilityDefaults() throws {
        let serial = try JSONDecoder().decode(Configuration.Serial.self, from: Data("{\"port\":\"/dev/cu.example\",\"baudRate\":9600,\"autoConnect\":true,\"framing\":\"newline\",\"debounceMs\":180}".utf8))
        XCTAssertEqual(serial.startupDelayMs, 2000)
        XCTAssertEqual(serial.heartbeatTimeoutMs, 0)
        XCTAssertNil(serial.deviceIdentity)
    }

    func testIdentityFollowsTheSameBoardAndRejectsAnotherBoard() {
        let identity = SerialDeviceIdentity(vendorID: 0x2341, productID: 0x43, serialNumber: "BOARD-A", locationID: 1)
        let moved = SerialDevice(path: "/dev/cu.new", identity: SerialDeviceIdentity(vendorID: 0x2341, productID: 0x43, serialNumber: "BOARD-A", locationID: 2))
        let other = SerialDevice(path: "/dev/cu.old", identity: SerialDeviceIdentity(vendorID: 0x2341, productID: 0x43, serialNumber: "BOARD-B"))
        XCTAssertEqual(SerialDeviceCatalog.resolve(path: other.path, identity: identity, devices: [other, moved]), moved)
        XCTAssertNil(SerialDeviceCatalog.resolve(path: other.path, identity: identity, devices: [other]))
        let duplicate = SerialDevice(path: "/dev/cu.duplicate", identity: moved.identity)
        XCTAssertNil(SerialDeviceCatalog.resolve(path: "/dev/cu.missing", identity: identity, devices: [moved, duplicate]))
    }

    func testBoardsWithoutSerialNumbersStayOnTheirUSBLocation() {
        let identity = SerialDeviceIdentity(vendorID: 1, productID: 2, locationID: 100)
        let wrong = SerialDevice(path: "/dev/cu.other", identity: SerialDeviceIdentity(vendorID: 1, productID: 2, locationID: 200))
        XCTAssertNil(SerialDeviceCatalog.resolve(path: wrong.path, identity: identity, devices: [wrong]))
    }

    func testRetryBackoffIsBoundedAndResettable() {
        var retry = SerialRetryBackoff()
        XCTAssertEqual((0..<8).map { _ in retry.nextDelayMs(initial: 500, maximum: 10000) }, [500, 1000, 2000, 4000, 8000, 10000, 10000, 10000])
        retry.reset()
        XCTAssertEqual(retry.nextDelayMs(initial: 500, maximum: 10000), 500)
    }

    func testRapidConnectDisconnectOnlyDeliversLatestSession() throws {
        let terminal = try TestTerminal()
        let transport = SerialTransport()
        let opened = expectation(description: "Latest session opens without a stale exclusive lock")
        transport.onStatus = { connected, message in
            XCTAssertTrue(connected, message)
            opened.fulfill()
        }
        for _ in 0..<100 {
            transport.connect(path: terminal.path, baudRate: 9600, framing: "newline")
            transport.disconnect()
        }
        transport.connect(path: terminal.path, baudRate: 115200, framing: "newline")
        wait(for: [opened], timeout: 5)
        let received = expectation(description: "Only the final session reads")
        transport.onCommand = { frame in XCTAssertEqual(frame, "1"); received.fulfill() }
        terminal.send("1\n")
        wait(for: [received], timeout: 2)
        transport.onStatus = nil
        let closed = expectation(description: "Descriptor close completes")
        transport.disconnect { closed.fulfill() }
        wait(for: [closed], timeout: 2)
    }

    func testStartupNoiseAndPartialCommandsAreDiscarded() throws {
        let terminal = try TestTerminal()
        let session = SerialConnection(deviceProvider: { [] }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(terminal)
        config.startupDelayMs = 300
        let received = expectation(description: "Only the command after startup executes")
        session.onStatus = { status in
            if status.phase == .settling { terminal.send("0\n0") }
            if status.phase == .connected { terminal.send("\n1\n") }
        }
        session.onCommand = { command in XCTAssertEqual(command, "1"); received.fulfill() }
        session.start(settings: config)
        wait(for: [received], timeout: 3)
    }

    func testReadyHandshakeEndsTheStartupWindow() throws {
        let terminal = try TestTerminal()
        let session = SerialConnection(deviceProvider: { [] }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(terminal)
        config.startupDelayMs = 3000
        let connected = expectation(description: "READY avoids waiting the full boot delay")
        session.onStatus = { status in
            if status.phase == .settling { terminal.send("READY\n") }
            if status.phase == .connected { connected.fulfill() }
        }
        session.start(settings: config)
        wait(for: [connected], timeout: 1)
    }

    func testQuietIdleConnectionDoesNotDropOrReopenOnDebounceChanges() throws {
        let terminal = try TestTerminal()
        let session = SerialConnection(deviceProvider: { [] }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(terminal)
        let received = expectation(description: "Idle board stays connected after settings update")
        var connections = 0
        session.onStatus = { status in
            if status.phase == .connected {
                connections += 1
                XCTAssertEqual(connections, 1, "Debounce changes must not reset the Arduino")
                config.debounceMs = 250
                session.configure(config)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { terminal.send("0\n") }
            }
        }
        session.onCommand = { command in XCTAssertEqual(command, "0"); received.fulfill() }
        session.start(settings: config)
        wait(for: [received], timeout: 3)
        XCTAssertEqual(connections, 1)
    }

    func testHeartbeatTimeoutIsOptInAndDetectsStalledFirmware() throws {
        let terminal = try TestTerminal()
        let session = SerialConnection(deviceProvider: { [] }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(terminal)
        config.heartbeatTimeoutMs = 350
        let timedOut = expectation(description: "Missing expected heartbeat triggers recovery")
        session.onStatus = { status in
            if status.phase == .connected { terminal.send("HEARTBEAT\n") }
            if status.phase == .waiting, status.message.contains("heartbeat timed out") { timedOut.fulfill(); session.stop() }
        }
        session.start(settings: config)
        wait(for: [timedOut], timeout: 2)
    }

    func testUnplugReplugFollowsIdentityToANewDevicePath() throws {
        let old = try TestTerminal(), replacement = try TestTerminal()
        XCTAssertNotEqual(old.path, replacement.path)
        let identity = SerialDeviceIdentity(vendorID: 1, productID: 2, serialNumber: "TEST-BOARD")
        let list = TestDeviceList()
        list.devices = [SerialDevice(path: old.path, identity: identity)]
        let session = SerialConnection(deviceProvider: { list.devices }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(old)
        config.deviceIdentity = identity
        let reconnected = expectation(description: "Same board reconnects on changed path")
        let command = expectation(description: "New connection discards old partial frame")
        session.onStatus = { status in
            guard status.phase == .connected else { return }
            if status.device?.path == old.path {
                old.send("0")
                list.devices = [SerialDevice(path: replacement.path, identity: identity)]
                old.unplug()
                session.refreshDevices()
            } else {
                XCTAssertEqual(status.device?.path, replacement.path)
                reconnected.fulfill()
                replacement.send("\n1\n")
            }
        }
        session.onCommand = { value in XCTAssertEqual(value, "1"); command.fulfill() }
        session.start(settings: config)
        wait(for: [reconnected, command], timeout: 4)
    }

    func testManualDisconnectCancelsFutureReconnect() throws {
        let terminal = try TestTerminal()
        let list = TestDeviceList()
        let session = SerialConnection(deviceProvider: { list.devices }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        var config = settings(terminal)
        config.port = "/dev/touchplayer-test-not-present"
        let stopped = expectation(description: "Operator cancels retry")
        let unwanted = expectation(description: "Stopped session never reconnects")
        unwanted.isInverted = true
        session.onStatus = { status in
            if status.phase == .waiting { session.stop() }
            if status.phase == .disconnected { stopped.fulfill() }
            if status.phase == .connected { unwanted.fulfill() }
        }
        session.start(settings: config)
        wait(for: [stopped], timeout: 2)
        list.devices = [SerialDevice(path: terminal.path)]
        session.refreshDevices()
        wait(for: [unwanted], timeout: 0.4)
    }

    func testWakeRecoversOnlyAnIntendedConnection() throws {
        let terminal = try TestTerminal()
        let session = SerialConnection(deviceProvider: { [] }, pollInterval: .milliseconds(20))
        defer { session.shutdown() }
        let config = settings(terminal)
        var count = 0
        let woke = expectation(description: "Serial descriptor is reopened after wake")
        session.onStatus = { status in
            if status.phase == .connected {
                count += 1
                if count == 1 { session.suspend() }
                else { XCTAssertEqual(count, 2); woke.fulfill() }
            }
            if status.phase == .suspended { session.resume() }
        }
        session.start(settings: config)
        wait(for: [woke], timeout: 4)
    }
}
