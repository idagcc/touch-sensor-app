import Foundation
import IOKit
import IOKit.serial

public struct SerialDeviceIdentity: Codable, Equatable {
    public var vendorID: Int
    public var productID: Int
    public var serialNumber: String?
    public var locationID: UInt32?
    public var interfaceNumber: Int?

    public init(vendorID: Int, productID: Int, serialNumber: String? = nil, locationID: UInt32? = nil, interfaceNumber: Int? = nil) {
        self.vendorID = vendorID; self.productID = productID
        self.serialNumber = serialNumber; self.locationID = locationID; self.interfaceNumber = interfaceNumber
    }

    public func matches(_ other: SerialDeviceIdentity) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID else { return false }
        if let interfaceNumber, interfaceNumber != other.interfaceNumber { return false }
        if let serialNumber, !serialNumber.isEmpty { return serialNumber == other.serialNumber }
        // Boards without unique serial numbers can only be followed on the same USB socket.
        return locationID != nil && locationID == other.locationID
    }
}

public struct SerialDevice: Equatable {
    public var path: String
    public var name: String
    public var identity: SerialDeviceIdentity?
    public init(path: String, name: String = "", identity: SerialDeviceIdentity? = nil) {
        self.path = path; self.name = name; self.identity = identity
    }
}

public enum SerialDeviceCatalog {
    public static func devices() -> [SerialDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, 0)
            }
            guard let path = property(service, kIOCalloutDeviceKey) as? String else { continue }
            // Stop at the nearest USB device. Searching serial-number properties
            // recursively could otherwise accidentally pick up a hub's identity.
            var usb = service
            IOObjectRetain(usb)
            var interfaceNumber: Int?
            while usb != 0 {
                if interfaceNumber == nil { interfaceNumber = (property(usb, "bInterfaceNumber") as? NSNumber)?.intValue }
                if IOObjectConformsTo(usb, "IOUSBHostDevice") != 0 || IOObjectConformsTo(usb, "IOUSBDevice") != 0 { break }
                var parent: io_registry_entry_t = 0
                let result = IORegistryEntryGetParentEntry(usb, kIOServicePlane, &parent)
                IOObjectRelease(usb)
                usb = result == KERN_SUCCESS ? parent : 0
            }
            defer { if usb != 0 { IOObjectRelease(usb) } }
            var identity: SerialDeviceIdentity?
            if usb != 0, let vendor = property(usb, "idVendor") as? NSNumber, let product = property(usb, "idProduct") as? NSNumber {
                let serial = (property(usb, "USB Serial Number") as? String).flatMap { $0.isEmpty ? nil : $0 }
                let location = (property(usb, "locationID") as? NSNumber)?.uint32Value
                if serial != nil || location != nil {
                    identity = SerialDeviceIdentity(vendorID: vendor.intValue, productID: product.intValue,
                        serialNumber: serial, locationID: location, interfaceNumber: interfaceNumber)
                }
            }
            let name = (usb != 0 ? property(usb, "USB Product Name") as? String : nil) ?? URL(fileURLWithPath: path).lastPathComponent
            devices.append(SerialDevice(path: path, name: name, identity: identity))
        }
        return devices.sorted { $0.path < $1.path }
    }

    public static func resolve(path: String, identity: SerialDeviceIdentity?, devices: [SerialDevice]) -> SerialDevice? {
        guard let identity else { return devices.first { $0.path == path } }
        let matches = devices.filter { $0.identity.map(identity.matches) == true }
        if let exact = matches.first(where: { $0.path == path }) { return exact }
        return matches.count == 1 ? matches.first : nil
    }
}

public struct SerialRetryBackoff {
    private var failures = 0
    public init() {}
    public mutating func reset() { failures = 0 }
    public mutating func nextDelayMs(initial: Int, maximum: Int) -> Int {
        let multiplier = 1 << min(failures, 16)
        failures = min(failures + 1, 16)
        return min(maximum, initial * multiplier)
    }
}
