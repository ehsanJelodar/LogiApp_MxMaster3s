import Foundation
import IOKit
import IOKit.hid


final class LogitechBatteryReader {

    // ========================================================
    // MARK: Constants
    // ========================================================

    private let vendorID: Int = 0x046D

    private let productID: Int = 0xB034

    private let reportIDLong: UInt8 = 0x11

    private let reportLengthLong: Int = 20

    private let deviceIndexBluetooth: UInt8 = 0xFF

    private let softwareID: UInt8 = 0x08

    private let rootFeatureIndex: UInt8 = 0x00

    private let unifiedBatteryFeatureID: UInt16 = 0x1004

    private let legacyBatteryFeatureID: UInt16 = 0x1000


    // ========================================================
    // MARK: HID device
    // ========================================================

    private var device: IOHIDDevice?

    private var manager: IOHIDManager?


    // ========================================================
    // MARK: Input callback storage
    // ========================================================

    private var inputBuffer:
        UnsafeMutablePointer<UInt8>?

    private let inputBufferSize: Int = 64


    // ========================================================
    // MARK: Run loop
    // ========================================================

    private var runLoop: CFRunLoop?


    // ========================================================
    // MARK: Response synchronization
    // ========================================================

    private let responseLock =
        NSLock()

    private var waitingForResponse =
        false

    private var response:
        [UInt8]?


    private var expectedDeviceIndex:
        UInt8 = 0

    private var expectedFeatureIndex:
        UInt8 = 0

    private var expectedFunction:
        UInt8 = 0

    private var expectedSoftwareID:
        UInt8 = 0


    // ========================================================
    // MARK: Read battery
    // ========================================================

    func readBattery() -> (name: String, percent: Int)? {

        guard let hidDevice =
            findMXMaster3S()
        else {
            return nil
        }

        device =
            hidDevice

        guard openDevice(
            hidDevice
        ) else {
            return nil
        }

        defer {
            cleanup()
        }

        guard setupInputCallback(
            hidDevice
        ) else {
            return nil
        }

        usleep(20_000)

        // ----------------------------------------------------
        // Discover Unified Battery.
        // ----------------------------------------------------

        guard let batteryFeatureIndex =
            getFeatureIndex(
                device: hidDevice,
                featureID: unifiedBatteryFeatureID
            )
        else {

            // ------------------------------------------------
            // Try legacy Battery Status 0x1000.
            // ------------------------------------------------

            if let legacyIndex =
                getFeatureIndex(
                    device: hidDevice,
                    featureID: legacyBatteryFeatureID
                ) {

                if let battery =
                    readLegacyBattery(
                        device: hidDevice,
                        featureIndex: legacyIndex
                    ) {

                    let name =
                        stringProperty(
                            hidDevice,
                            kIOHIDProductKey
                        ) ?? "Logitech Device"

                    return (
                        name: name,
                        percent: battery.percentage
                    )
                }
            }

            return nil
        }

        // ----------------------------------------------------
        // Battery capabilities.
        // ----------------------------------------------------

        guard let capabilities =
            readBatteryCapabilities(
                device: hidDevice,
                featureIndex: batteryFeatureIndex
            )
        else {
            return nil
        }

        guard capabilities.percentage else {
            return nil
        }

        // ----------------------------------------------------
        // Battery status.
        // ----------------------------------------------------

        guard let battery =
            readBatteryStatus(
                device: hidDevice,
                featureIndex: batteryFeatureIndex
            )
        else {
            return nil
        }

        let name =
            stringProperty(
                hidDevice,
                kIOHIDProductKey
            ) ?? "Logitech Device"

        return (
            name: name,
            percent: battery.percentage
        )
    }


    // ========================================================
    // MARK: Find device
    // ========================================================

    private func findMXMaster3S()
        -> IOHIDDevice?
    {

        let hidManager =
            IOHIDManagerCreate(
                kCFAllocatorDefault,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            )

        manager =
            hidManager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey:
                vendorID
        ]

        IOHIDManagerSetDeviceMatching(
            hidManager,
            matching as CFDictionary
        )

        let openResult =
            IOHIDManagerOpen(
                hidManager,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            )

        guard openResult ==
                kIOReturnSuccess
        else {
            return nil
        }

        defer {
            IOHIDManagerClose(
                hidManager,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            )
        }

        guard let devices =
            IOHIDManagerCopyDevices(
                hidManager
            ) as? Set<IOHIDDevice>
        else {
            return nil
        }

        for hidDevice in devices {

            let vid =
                numberProperty(
                    hidDevice,
                    kIOHIDVendorIDKey
                ) ?? 0

            let pid =
                numberProperty(
                    hidDevice,
                    kIOHIDProductIDKey
                ) ?? 0

            let product =
                stringProperty(
                    hidDevice,
                    kIOHIDProductKey
                ) ?? ""

            let manufacturer =
                stringProperty(
                    hidDevice,
                    kIOHIDManufacturerKey
                ) ?? ""

            let transport =
                stringProperty(
                    hidDevice,
                    kIOHIDTransportKey
                ) ?? ""

            _ = vid
            _ = manufacturer
            _ = transport

            let matchesPID =
                pid == productID

            let matchesName =
                product
                    .localizedCaseInsensitiveContains(
                        "MX Master 3S"
                    )

            if matchesPID ||
               matchesName {

                return hidDevice
            }
        }

        return nil
    }


    // ========================================================
    // MARK: Device info
    // ========================================================

    private func printDeviceInfo(
        _ device: IOHIDDevice
    ) {

        let vid =
            numberProperty(
                device,
                kIOHIDVendorIDKey
            ) ?? 0

        let pid =
            numberProperty(
                device,
                kIOHIDProductIDKey
            ) ?? 0

        let product =
            stringProperty(
                device,
                kIOHIDProductKey
            ) ?? ""

        let manufacturer =
            stringProperty(
                device,
                kIOHIDManufacturerKey
            ) ?? ""

        let transport =
            stringProperty(
                device,
                kIOHIDTransportKey
            ) ?? ""

        _ = vid
        _ = pid
        _ = product
        _ = manufacturer
        _ = transport
    }


    // ========================================================
    // MARK: Open
    // ========================================================

    private func openDevice(
        _ device: IOHIDDevice
    ) -> Bool {

        let result =
            IOHIDDeviceOpen(
                device,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            )

        return result ==
            kIOReturnSuccess
    }


    // ========================================================
    // MARK: Input callback
    // ========================================================

    private func setupInputCallback(
        _ device: IOHIDDevice
    ) -> Bool {

        runLoop =
            CFRunLoopGetCurrent()

        guard let loop =
            runLoop
        else {
            return false
        }

        let buffer =
            UnsafeMutablePointer<UInt8>
                .allocate(
                    capacity:
                        inputBufferSize
                )

        buffer.initialize(
            repeating: 0,
            count:
                inputBufferSize
        )

        inputBuffer =
            buffer

        let context =
            Unmanaged
                .passUnretained(
                    self
                )
                .toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            inputBufferSize,
            {
                context,
                result,
                sender,
                reportType,
                reportID,
                report,
                reportLength
            in

                guard
                    let context = context
                else {
                    return
                }

                let reader =
                    Unmanaged<
                        LogitechBatteryReader
                    >
                    .fromOpaque(
                        context
                    )
                    .takeUnretainedValue()

                reader.handleInputReport(
                    result:
                        result,
                    reportID:
                        reportID,
                    report:
                        report,
                    reportLength:
                        reportLength
                )
            },
            context
        )

        IOHIDDeviceScheduleWithRunLoop(
            device,
            loop,
            CFRunLoopMode.defaultMode.rawValue
        )

        return true
    }


    // ========================================================
    // MARK: Input report handler
    // ========================================================

    private func handleInputReport(
        result: IOReturn,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {

        guard result ==
                kIOReturnSuccess
        else {
            return
        }

        guard reportLength > 0 else {
            return
        }

        let bytes =
            Array(
                UnsafeBufferPointer(
                    start:
                        report,
                    count:
                        reportLength
                )
            )

        guard
            reportID == UInt32(reportIDLong)
        else {
            return
        }

        guard
            bytes.count >= 4
        else {
            return
        }

        guard
            bytes[0] == reportIDLong
        else {
            return
        }

        let deviceIndex =
            bytes[1]

        let featureIndex =
            bytes[2]

        let functionSoftware =
            bytes[3]

        let function =
            (functionSoftware >> 4) &
            0x0F

        let software =
            functionSoftware &
            0x0F

        responseLock.lock()

        let matches =
            waitingForResponse &&
            deviceIndex ==
                expectedDeviceIndex &&
            featureIndex ==
                expectedFeatureIndex &&
            function ==
                expectedFunction &&
            software ==
                expectedSoftwareID

        if matches {

            response =
                bytes

            waitingForResponse =
                false
        }

        responseLock.unlock()

        if matches {

            if let loop =
                runLoop {

                CFRunLoopStop(
                    loop
                )
            }
        }
    }


    // ========================================================
    // MARK: Send HID++ request
    // ========================================================

    private func sendRequest(
        device: IOHIDDevice,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval = 2.0
    ) -> [UInt8]?
    {

        var request =
            [UInt8](
                repeating: 0,
                count:
                    reportLengthLong
            )

        request[0] =
            reportIDLong

        request[1] =
            deviceIndexBluetooth

        request[2] =
            featureIndex

        request[3] =
            ((function & 0x0F) << 4) |
            (softwareID & 0x0F)

        let parameterCount =
            min(
                parameters.count,
                16
            )

        if parameterCount > 0 {

            for index in
                0..<parameterCount {

                request[4 + index] =
                    parameters[index]
            }
        }

        responseLock.lock()

        waitingForResponse =
            true

        response =
            nil

        expectedDeviceIndex =
            deviceIndexBluetooth

        expectedFeatureIndex =
            featureIndex

        expectedFunction =
            function

        expectedSoftwareID =
            softwareID

        responseLock.unlock()

        let sendResult =
            request.withUnsafeBytes {
                rawBuffer -> IOReturn in

                guard let pointer =
                    rawBuffer.baseAddress
                else {

                    return kIOReturnBadArgument
                }

                return IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(reportIDLong),
                    pointer
                        .assumingMemoryBound(
                            to: UInt8.self
                        ),
                    CFIndex(request.count)
                )
            }

        guard sendResult ==
                kIOReturnSuccess
        else {

            responseLock.lock()

            waitingForResponse =
                false

            responseLock.unlock()

            return nil
        }

        let deadline =
            Date()
                .addingTimeInterval(
                    timeout
                )

        while Date() < deadline {

            responseLock.lock()

            if let received =
                response {

                response =
                    nil

                waitingForResponse =
                    false

                responseLock.unlock()

                return received
            }

            responseLock.unlock()

            let remaining =
                deadline.timeIntervalSinceNow

            if remaining <= 0 {
                break
            }

            let interval =
                min(
                    0.05,
                    remaining
                )

            CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                interval,
                false
            )
        }

        responseLock.lock()

        let timedOutResponse =
            response

        response =
            nil

        waitingForResponse =
            false

        responseLock.unlock()

        return timedOutResponse
    }


    // ========================================================
    // MARK: ROOT.getFeature
    // ========================================================

    private func getFeatureIndex(
        device: IOHIDDevice,
        featureID: UInt16
    ) -> UInt8?
    {

        let high =
            UInt8(
                (featureID >> 8) &
                0xFF
            )

        let low =
            UInt8(
                featureID &
                0xFF
            )

        guard let response =
            sendRequest(
                device:
                    device,
                featureIndex:
                    rootFeatureIndex,
                function:
                    0x00,
                parameters:
                    [
                        high,
                        low,
                        0x00
                    ]
            )
        else {

            return nil
        }

        guard response.count >= 7 else {
            return nil
        }

        if response[2] == 0xFF {
            return nil
        }

        let index =
            response[4]

        let type =
            response[5]

        _ = type

        return index
    }


    // ========================================================
    // MARK: Battery capabilities
    // ========================================================

    private func readBatteryCapabilities(
        device: IOHIDDevice,
        featureIndex: UInt8
    ) -> BatteryCapabilities?
    {

        guard let response =
            sendRequest(
                device:
                    device,
                featureIndex:
                    featureIndex,
                function:
                    0x00,
                parameters:
                    [
                        0x00,
                        0x00,
                        0x00
                    ]
            )
        else {

            return nil
        }

        guard response.count >= 7 else {
            return nil
        }

        let levels =
            response[4]

        let flags =
            response[5]

        let rechargeable =
            (flags & 0x01) != 0

        let percentage =
            (flags & 0x02) != 0

        return BatteryCapabilities(
            levels:
                levels,
            rechargeable:
                rechargeable,
            percentage:
                percentage
        )
    }


    // ========================================================
    // MARK: Battery status
    // ========================================================

    private func readBatteryStatus(
        device: IOHIDDevice,
        featureIndex: UInt8
    ) -> BatteryInfo?
    {

        guard let response =
            sendRequest(
                device:
                    device,
                featureIndex:
                    featureIndex,
                function:
                    0x01,
                parameters:
                    [
                        0x00,
                        0x00,
                        0x00
                    ]
            )
        else {

            return nil
        }

        guard response.count >= 7 else {
            return nil
        }

        let percentage =
            Int(
                response[4]
            )

        let level =
            response[5]

        let chargingStatus =
            response[6]

        guard percentage <= 100 else {
            return nil
        }

        return BatteryInfo(
            percentage:
                percentage,
            level:
                level,
            chargingStatus:
                chargingStatus
        )
    }


    // ========================================================
    // MARK: Legacy battery
    // ========================================================

    private func readLegacyBattery(
        device: IOHIDDevice,
        featureIndex: UInt8
    ) -> BatteryInfo?
    {

        guard let response =
            sendRequest(
                device:
                    device,
                featureIndex:
                    featureIndex,
                function:
                    0x00,
                parameters:
                    [
                        0x00,
                        0x00,
                        0x00
                    ]
            )
        else {

            return nil
        }

        guard response.count >= 7 else {
            return nil
        }

        let percentage =
            Int(
                response[4]
            )

        let level =
            response[5]

        let status =
            response[6]

        guard percentage <= 100 else {
            return nil
        }

        return BatteryInfo(
            percentage:
                percentage,
            level:
                level,
            chargingStatus:
                status
        )
    }


    // ========================================================
    // MARK: Charging status
    // ========================================================

    private func chargingStatusName(
        _ status: UInt8
    ) -> String {

        switch status {

        case 0x00:
            return "Discharging"

        case 0x01:
            return "Charging"

        case 0x02:
            return "Charging slowly"

        case 0x03:
            return "Full"

        case 0x04:
            return "Error"

        default:
            return String(
                format:
                "Unknown (0x%02X)",
                status
            )
        }
    }


    // ========================================================
    // MARK: HID dump
    // ========================================================

    private func dumpHIDElements(
        _ device: IOHIDDevice
    ) {

        guard let elements =
            IOHIDDeviceCopyMatchingElements(
                device,
                nil,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            ) as? [IOHIDElement]
        else {
            return
        }

        for (index, element)
            in elements.enumerated() {

            let type =
                IOHIDElementGetType(
                    element
                )

            let page =
                IOHIDElementGetUsagePage(
                    element
                )

            let usage =
                IOHIDElementGetUsage(
                    element
                )

            let reportID =
                IOHIDElementGetReportID(
                    element
                )

            let reportSize =
                IOHIDElementGetReportSize(
                    element
                )

            let reportCount =
                IOHIDElementGetReportCount(
                    element
                )

            let logicalMin =
                IOHIDElementGetLogicalMin(
                    element
                )

            let logicalMax =
                IOHIDElementGetLogicalMax(
                    element
                )

            let name =
                IOHIDElementGetName(
                    element
                ) as String? ?? ""

            _ = index
            _ = type
            _ = page
            _ = usage
            _ = reportID
            _ = reportSize
            _ = reportCount
            _ = logicalMin
            _ = logicalMax
            _ = name
        }
    }


    // ========================================================
    // MARK: Cleanup
    // ========================================================

    private func cleanup() {

        if let hidDevice =
            device {

            if let loop =
                runLoop {

                IOHIDDeviceUnscheduleFromRunLoop(
                    hidDevice,
                    loop,
                    CFRunLoopMode.defaultMode.rawValue
                )
            }

            IOHIDDeviceClose(
                hidDevice,
                IOOptionBits(
                    kIOHIDOptionsTypeNone
                )
            )
        }

        if let buffer =
            inputBuffer {

            buffer.deinitialize(
                count:
                    inputBufferSize
            )

            buffer.deallocate()

            inputBuffer =
                nil
        }

        device =
            nil

        runLoop =
            nil

        manager =
            nil
    }


    // ========================================================
    // MARK: Helpers
    // ========================================================

    private func numberProperty(
        _ device: IOHIDDevice,
        _ key: String
    ) -> Int?
    {

        return (
            IOHIDDeviceGetProperty(
                device,
                key as CFString
            ) as? NSNumber
        )?.intValue
    }


    private func stringProperty(
        _ device: IOHIDDevice,
        _ key: String
    ) -> String?
    {

        return IOHIDDeviceGetProperty(
            device,
            key as CFString
        ) as? String
    }


    private func hex(
        _ bytes: [UInt8]
    ) -> String {

        return bytes
            .map {
                String(
                    format:
                    "%02X",
                    $0
                )
            }
            .joined(
                separator:
                    " "
            )
    }
}


// ============================================================
// MARK: Data structures
// ============================================================

private struct BatteryCapabilities {

    let levels: UInt8

    let rechargeable: Bool

    let percentage: Bool
}


private struct BatteryInfo {

    let percentage: Int

    let level: UInt8

    let chargingStatus: UInt8
}


struct BatteryHelper {
    static func getBattery() -> (name: String, percent: Int)? {
        let r = LogitechBatteryReader()
        return r.readBattery()

    }
}

