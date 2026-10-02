
// ============================================================
// MX Master 3S HID++ Battery Reader
//
// Target:
//   macOS Big Sur
//   Swift 5.x
//
// Direct Bluetooth HID++:
//   Vendor ID       = 0x046D
//   Product ID      = 0xB034
//   HID++ report    = 0x11 (long report)
//   Report length   = 20 bytes
//   Device index    = 0xFF
//
// Protocol:
//   ROOT feature discovery
//   Unified Battery 0x1004
//
// Important:
//   The feature index is NOT hardcoded.
//   It is resolved through ROOT.getFeature(0x1004).
//
//   Responses are received through the HID input-report
//   callback.
//
//   The command itself is sent with IOHIDDeviceSetReport.
//   build : swiftc -O -o AppName  battery_mx_test.swift 
// ============================================================

import Foundation
import IOKit
import IOKit.hid


final class MXMaster3SBatteryReader {

    // ========================================================
    // MARK: Constants
    // ========================================================

    private let vendorID: Int = 0x046D

    private let productID: Int = 0xB034

    private let reportIDLong: UInt8 = 0x11

    private let reportLengthLong: Int = 20

    private let deviceIndexBluetooth: UInt8 = 0xFF

    // Software ID.
    //
    // Must be non-zero so that responses can be matched.
    private let softwareID: UInt8 = 0x08

    // HID++ ROOT feature.
    private let rootFeatureIndex: UInt8 = 0x00

    // Unified Battery feature.
    private let unifiedBatteryFeatureID: UInt16 = 0x1004

    // Legacy Battery Status.
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
    // MARK: RUN
    // ========================================================

    func run() {

        print("")
        print("================================================")
        print("       MX MASTER 3S HID++ BATTERY READER")
        print("================================================")
        print("")
        print("macOS Big Sur / Swift 5.x")
        print("")

        guard let hidDevice =
            findMXMaster3S()
        else {

            print("")
            print("❌ MX Master 3S was not found.")
            print("")
            return
        }

        device =
            hidDevice

        print("")
        print("================================================")
        print("                  DEVICE")
        print("================================================")
        print("")

        printDeviceInfo(
            hidDevice
        )

        guard openDevice(
            hidDevice
        ) else {

            return
        }

        defer {
            cleanup()
        }

        // ----------------------------------------------------
        // Set up asynchronous input reports.
        // ----------------------------------------------------

        guard setupInputCallback(
            hidDevice
        ) else {

            print("")
            print("❌ Could not configure HID input callback.")
            print("")

            return
        }

        // ----------------------------------------------------
        // Give the HID system a moment to finish scheduling.
        // ----------------------------------------------------

        usleep(20_000)

        // ----------------------------------------------------
        // Discover Unified Battery.
        // ----------------------------------------------------

        print("")
        print("================================================")
        print("             FEATURE DISCOVERY")
        print("================================================")
        print("")

        guard let batteryFeatureIndex =
            getFeatureIndex(
                device: hidDevice,
                featureID: unifiedBatteryFeatureID
            )
        else {

            print("")
            print("❌ Unified Battery 0x1004 could not be")
            print("   resolved.")
            print("")

            print("Trying legacy Battery Status 0x1000...")
            print("")

            if let legacyIndex =
                getFeatureIndex(
                    device: hidDevice,
                    featureID: legacyBatteryFeatureID
                ) {

                print(
                    String(
                        format:
                        "✅ Legacy Battery feature index = 0x%02X",
                        legacyIndex
                    )
                )

                if let battery =
                    readLegacyBattery(
                        device: hidDevice,
                        featureIndex: legacyIndex
                    ) {

                    printBatteryResult(
                        battery
                    )
                }

            } else {

                print("")
                print("❌ No battery feature could be resolved.")
                print("")
                print("At this point the HID transport itself")
                print("needs to be investigated.")
                print("")
            }

            return
        }

        print("")
        print(
            String(
                format:
                "✅ Unified Battery feature index = 0x%02X",
                batteryFeatureIndex
            )
        )

        // ----------------------------------------------------
        // Capabilities
        // ----------------------------------------------------

        print("")
        print("================================================")
        print("             BATTERY CAPABILITIES")
        print("================================================")
        print("")

        guard let capabilities =
            readBatteryCapabilities(
                device: hidDevice,
                featureIndex: batteryFeatureIndex
            )
        else {

            print("")
            print("❌ Could not read battery capabilities.")
            print("")

            return
        }

        print(
            String(
                format:
                "Reported levels : 0x%02X",
                capabilities.levels
            )
        )

        print(
            "Rechargeable    : \(capabilities.rechargeable)"
        )

        print(
            "Percentage      : \(capabilities.percentage)"
        )

        guard capabilities.percentage else {

            print("")
            print("❌ Device does not advertise battery")
            print("   percentage support.")
            print("")

            return
        }

        // ----------------------------------------------------
        // Battery status
        // ----------------------------------------------------

        print("")
        print("================================================")
        print("               BATTERY STATUS")
        print("================================================")
        print("")

        guard let battery =
            readBatteryStatus(
                device: hidDevice,
                featureIndex: batteryFeatureIndex
            )
        else {

            print("")
            print("❌ Could not read battery status.")
            print("")

            return
        }

        printBatteryResult(
            battery
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

            print(
                String(
                    format:
                    "❌ IOHIDManagerOpen failed: 0x%08X",
                    openResult
                )
            )

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

            print(
                "❌ IOHIDManagerCopyDevices failed."
            )

            return nil
        }

        print(
            "Logitech HID devices: \(devices.count)"
        )

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

            print("")

            print(
                String(
                    format:
                    "VID=0x%04X PID=0x%04X",
                    vid,
                    pid
                )
            )

            print(
                "Product      : \(product)"
            )

            print(
                "Manufacturer : \(manufacturer)"
            )

            print(
                "Transport    : \(transport)"
            )

            let matchesPID =
                pid == productID

            let matchesName =
                product
                    .localizedCaseInsensitiveContains(
                        "MX Master 3S"
                    )

            if matchesPID ||
               matchesName {

                print("")
                print(">>> MX Master 3S MATCH")
                print("")

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

        print(
            String(
                format:
                "Vendor       : 0x%04X",
                vid
            )
        )

        print(
            String(
                format:
                "Product ID   : 0x%04X",
                pid
            )
        )

        print(
            "Product      : \(product)"
        )

        print(
            "Manufacturer : \(manufacturer)"
        )

        print(
            "Transport    : \(transport)"
        )
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

        print("")
        print(
            String(
                format:
                "IOHIDDeviceOpen: 0x%08X",
                result
            )
        )

        if result ==
            kIOReturnNotPermitted {

            print("")
            print("❌ macOS denied HID access.")
            print("")
            print("Enable:")
            print("")
            print("System Settings")
            print("  → Privacy & Security")
            print("  → Input Monitoring")
            print("")
            print("for the application running this code.")
            print("")
        }

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

            print(
                "❌ CFRunLoopGetCurrent returned nil."
            )

            return false
        }

        // ----------------------------------------------------
        // Allocate persistent input buffer.
        // ----------------------------------------------------

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
                        MXMaster3SBatteryReader
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

        print("")
        print("✅ HID input callback registered.")
        print(
            "   Report buffer: \(inputBufferSize) bytes"
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

        print("")
        print(
            "INPUT REPORT:"
        )

        print(
            hex(bytes)
        )

        print(
            String(
                format:
                "reportID=0x%02X length=%d",
                reportID,
                reportLength
            )
        )

        // ----------------------------------------------------
        // We only care about HID++ long report 0x11.
        //
        // Normal mouse motion reports can arrive through the
        // same physical HID device and must NOT be interpreted
        // as HID++.
        // ----------------------------------------------------

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

        print(
            String(
                format:
                "HID++ RX device=0x%02X feature=0x%02X function=0x%02X software=0x%02X",
                deviceIndex,
                featureIndex,
                function,
                software
            )
        )

        // ----------------------------------------------------
        // Only match the request we are currently waiting for.
        // ----------------------------------------------------

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

        // ----------------------------------------------------
        // Bluetooth uses long report 0x11.
        //
        // Complete report:
        //
        // byte 0  = 0x11
        // byte 1  = device index 0xFF
        // byte 2  = feature index
        // byte 3  = function/software ID
        // byte 4+ = parameters
        //
        // Total = 20 bytes.
        // ----------------------------------------------------

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

        print("")
        print(
            "================================================"
        )
        print("HID++ REQUEST")
        print(
            "================================================"
        )

        print(
            "TX: \(hex(request))"
        )

        print(
            String(
                format:
                "  report=0x%02X device=0x%02X feature=0x%02X function=%d software=0x%02X",
                reportIDLong,
                deviceIndexBluetooth,
                featureIndex,
                function,
                softwareID
            )
        )

        // ----------------------------------------------------
        // Set response state BEFORE transmission.
        // ----------------------------------------------------

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

        // ----------------------------------------------------
        // Send using IOHIDDeviceSetReport.
        // ----------------------------------------------------

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

        print(
            String(
                format:
                "IOHIDDeviceSetReport OUTPUT: 0x%08X",
                sendResult
            )
        )

        guard sendResult ==
                kIOReturnSuccess
        else {

            print("")
            print(
                "❌ HID++ transmission failed."
            )

            responseLock.lock()

            waitingForResponse =
                false

            responseLock.unlock()

            return nil
        }

        // ----------------------------------------------------
        // Wait for asynchronous input report.
        //
        // The callback stops the run loop when the matching
        // response arrives.
        // ----------------------------------------------------

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

                print(
                    "RX MATCH: \(hex(received))"
                )

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

        if let received =
            timedOutResponse {

            print(
                "RX AFTER WAIT: \(hex(received))"
            )

            return received
        }

        print("")
        print(
            "❌ HID++ request timed out."
        )

        return nil
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

        print("")
        print(
            String(
                format:
                "ROOT.getFeature(0x%04X)",
                featureID
            )
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

        print(
            "ROOT response: \(hex(response))"
        )

        guard response.count >= 7 else {

            print(
                "❌ ROOT response too short."
            )

            return nil
        }

        // ----------------------------------------------------
        // HID++ error response.
        //
        // Feature index 0xFF means error.
        // ----------------------------------------------------

        if response[2] == 0xFF {

            let errorCode =
                response[4]

            print(
                String(
                    format:
                    "❌ HID++ ROOT error: 0x%02X",
                    errorCode
                )
            )

            print(
                hidppErrorName(
                    errorCode
                )
            )

            return nil
        }

        let index =
            response[4]

        let type =
            response[5]

        print(
            String(
                format:
                "Feature 0x%04X -> index=0x%02X type=0x%02X",
                featureID,
                index,
                type
            )
        )

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

        print("")
        print(
            "Unified Battery getCapabilities"
        )

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

        print(
            "Battery capabilities:"
        )

        print(
            hex(response)
        )

        guard response.count >= 7 else {

            print(
                "❌ Battery capability response too short."
            )

            return nil
        }

        // HID++ response:
        //
        // 0 = report
        // 1 = device
        // 2 = feature
        // 3 = function/software
        // 4 = reported levels
        // 5 = flags
        //

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

        print("")
        print(
            "Unified Battery getBatteryInfo"
        )

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

        print(
            "Battery status:"
        )

        print(
            hex(response)
        )

        guard response.count >= 7 else {

            print(
                "❌ Battery status response too short."
            )

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

            print(
                String(
                    format:
                    "❌ Invalid battery percentage: %d",
                    percentage
                )
            )

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

        print("")
        print(
            "Legacy Battery Status"
        )

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

        print(
            "Legacy response:"
        )

        print(
            hex(response)
        )

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
    // MARK: Result
    // ========================================================

    private func printBatteryResult(
        _ battery: BatteryInfo
    ) {

        print("")
        print(
            "================================================"
        )
        print(
            "                    RESULT"
        )
        print(
            "================================================"
        )
        print("")

        print(
            "🔋 Battery percentage : \(battery.percentage)%"
        )

        print(
            String(
                format:
                "Battery level       : 0x%02X",
                battery.level
            )
        )

        print(
            String(
                format:
                "Charging status     : 0x%02X",
                battery.chargingStatus
            )
        )

        print(
            "Charging state      : " +
            chargingStatusName(
                battery.chargingStatus
            )
        )

        print("")
    }


    // ========================================================
    // MARK: HID++ errors
    // ========================================================

    private func hidppErrorName(
        _ error: UInt8
    ) -> String {

        switch error {

        case 0x01:
            return "INVALID_ARGUMENT"

        case 0x02:
            return "OUT_OF_RANGE"

        case 0x03:
            return "HARDWARE_ERROR"

        case 0x04:
            return "LOGITECH_INTERNAL_ERROR"

        case 0x05:
            return "INVALID_FEATURE_INDEX"

        case 0x06:
            return "INVALID_FUNCTION_ID"

        case 0x07:
            return "BUSY"

        case 0x08:
            return "UNSUPPORTED"

        case 0x09:
            return "RESOURCE_ERROR"

        case 0x0A:
            return "REQUEST_NOT_ALLOWED"

        default:
            return String(
                format:
                "Unknown HID++ error 0x%02X",
                error
            )
        }
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

            print(
                "❌ Could not enumerate HID elements."
            )

            return
        }

        print("")
        print(
            "================================================"
        )
        print(
            "                 HID ELEMENTS"
        )
        print(
            "================================================"
        )
        print("")

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

            print(
                String(
                    format:
                    "[%03d] type=%d page=0x%04X usage=0x%04X report=0x%02X size=%d count=%d logical=%lld..%lld name='%@'",
                    index,
                    type.rawValue,
                    page,
                    usage,
                    reportID,
                    reportSize,
                    reportCount,
                    logicalMin,
                    logicalMax,
                    name
                )
            )
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

        // ----------------------------------------------------
        // Free callback buffer.
        // ----------------------------------------------------

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


// ============================================================
// MAIN
// ============================================================

let reader =
    MXMaster3SBatteryReader()

reader.run()
