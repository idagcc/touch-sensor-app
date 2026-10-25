import XCTest
import Darwin
@testable import TouchPlayerCore

final class TouchPlayerTests: XCTestCase {
    func testSerialFramesAcrossReadsAndCRLF() {
        var framer = CommandFramer()
        XCTAssertEqual(framer.feed(Array("STA".utf8)), [])
        XCTAssertEqual(framer.feed(Array("RT\r\n1\n2".utf8)), ["START", "1"])
        XCTAssertEqual(framer.feed(Array("\n 0 \n".utf8)), ["2", "0"])
    }

    func testOversizedFramesNeverBecomeCommands() {
        var framer = CommandFramer()
        XCTAssertEqual(framer.feed(Array(repeating: 65, count: 300) + Array("1\n2\n".utf8)), ["2"])
        XCTAssertEqual(framer.feed([0xff, 10, 48, 10]), ["0"])
    }

    func testByteFramingForSerialWrite() {
        var framer = CommandFramer(mode: "byte")
        XCTAssertEqual(framer.feed([48, 49, 13, 10, 50]), ["0", "1", "2"])
    }

    func testRepeatedButtonEdgesDebouncedButOtherCommandsImmediate() {
        let router = CommandRouter()
        let config = Configuration()
        XCTAssertEqual(router.route("0", configuration: config, now: 1_000_000_000), .toggle)
        XCTAssertNil(router.route("0", configuration: config, now: 1_010_000_000))
        XCTAssertEqual(router.route("1", configuration: config, now: 1_020_000_000), .reset)
        XCTAssertEqual(router.route("0", configuration: config, now: 1_030_000_000), .toggle)
        XCTAssertEqual(router.route("0", configuration: config, now: 1_220_000_000), .toggle)
        XCTAssertNil(router.route("2", configuration: config))
        XCTAssertNil(router.route("Arduino ready", configuration: config))
    }

    func testPlaybackTransitionsAndCompletion() {
        var player = PlaybackMachine()
        XCTAssertEqual(player.apply(.pause), .holding)
        XCTAssertEqual(player.apply(.toggle), .playing)
        XCTAssertEqual(player.apply(.toggle), .paused)
        XCTAssertEqual(player.apply(.play), .playing)
        player.finish(returnToHolding: false)
        XCTAssertEqual(player.state, .finished)
        XCTAssertEqual(player.apply(.toggle), .playing)
        XCTAssertEqual(player.apply(.reset), .holding)
        XCTAssertEqual(player.apply(.restart), .playing)
        player.finish(returnToHolding: true)
        XCTAssertEqual(player.state, .holding)
    }

    func testPalmTouchCommandSequence() throws {
        let config = Configuration()
        XCTAssertEqual(config.commands, ["0": .toggle, "1": .reset])
        let router = CommandRouter()
        var player = PlaybackMachine()
        func send(_ command: String, at time: UInt64) throws -> PlaybackState {
            player.apply(try XCTUnwrap(router.route(command, configuration: config, now: time)))
        }
        XCTAssertEqual(try send("0", at: 1_000_000_000), .playing)
        XCTAssertEqual(try send("0", at: 2_000_000_000), .paused)
        XCTAssertEqual(try send("0", at: 3_000_000_000), .playing)
        XCTAssertEqual(try send("1", at: 3_050_000_000), .holding)
        XCTAssertEqual(try send("0", at: 4_000_000_000), .playing)
        XCTAssertEqual(try send("0", at: 5_000_000_000), .paused)
        XCTAssertEqual(try send("1", at: 5_050_000_000), .holding)
        XCTAssertEqual(try send("1", at: 6_000_000_000), .holding)
        XCTAssertEqual(try send("0", at: 7_000_000_000), .playing)
        player.finish(returnToHolding: true)
        XCTAssertEqual(player.state, .holding)
    }

    func testConfigurationValidationAndAtomicSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(root: root)
        let original = try store.load()
        var invalid = original
        invalid.output.height = 0
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), original)
        invalid = original
        invalid.serial.framing = "byte"
        invalid.commands["START"] = .play
        XCTAssertThrowsError(try invalid.validate())
        var custom = original
        custom.output.width = 3840
        custom.output.height = 720
        custom.commands = ["START": .play, "STOP": .reset]
        try store.save(custom)
        XCTAssertEqual(try store.load(), custom)
    }

    func testMediaDiscoverySortsAndIgnoresNonVideoFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(root: root)
        _ = try store.media(in: "media/holding")
        for name in ["10.mp4", "2.MOV", "notes.txt", ".hidden.mp4"] {
            try Data().write(to: store.folder("media/holding").appendingPathComponent(name))
        }
        XCTAssertEqual(try store.media(in: "media/holding").map(\.lastPathComponent), ["2.MOV", "10.mp4"])
    }

    func testRealSerialDeviceReadAndReconnect() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        guard master >= 0, slave >= 0 else { return }
        let device = String(cString: path)
        close(slave)
        defer { close(master) }
        let transport = SerialTransport()
        let first = expectation(description: "Initial serial connection")
        transport.onStatus = { connected, message in
            XCTAssertTrue(connected, message)
            first.fulfill()
        }
        transport.connect(path: device, baudRate: 9600, framing: "newline")
        wait(for: [first], timeout: 3)
        let command = expectation(description: "Framed command received through real descriptor")
        transport.onCommand = { value in XCTAssertEqual(value, "1"); command.fulfill() }
        _ = "1\r\n".withCString { write(master, $0, 3) }
        wait(for: [command], timeout: 3)
        let reconnected = expectation(description: "Reconnect closes old descriptor before opening")
        transport.onStatus = { connected, message in
            XCTAssertTrue(connected, message)
            reconnected.fulfill()
        }
        transport.connect(path: device, baudRate: 115200, framing: "byte")
        wait(for: [reconnected], timeout: 3)
        let byte = expectation(description: "Byte protocol after reconnect")
        transport.onCommand = { value in XCTAssertEqual(value, "2"); byte.fulfill() }
        _ = "2".withCString { write(master, $0, 1) }
        wait(for: [byte], timeout: 3)
        let disconnected = expectation(description: "Disconnect finishes cleanup")
        transport.onStatus = { connected, _ in XCTAssertFalse(connected); disconnected.fulfill() }
        transport.disconnect()
        wait(for: [disconnected], timeout: 3)
    }
}
