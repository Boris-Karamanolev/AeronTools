import AppKit
import IOKit
import IOKit.hid
import IOKit.ps

extension MXMasterManager {
    // MARK: - IOHIDManager & Hardware Discovery

    func setupHIDManager() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: HIDPPProtocol.logitechVendorID
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.refreshDeviceState()
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.refreshDeviceState()
            }
        }, context)

        // Registered on the manager (not per device) so IOKit owns the report buffer; replies are filtered by sender.
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, reportLength in
            guard let context, let sender, reportLength > 0,
                  reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard mgr.activeHIDDevice === device else { return }
                mgr.handleIncomingHIDReport(reportID: UInt8(reportID & 0xFF), bytes: bytes)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.hidManager = manager

        hasInputMonitoringAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if hasInputMonitoringAccess {
            openHIDManager()
        } else {
            requestInputMonitoringAccess()
        }
    }

    /// Only called once Input Monitoring is granted: opening without access implicitly triggers the TCC prompt,
    /// which blocks the calling thread — and with our event taps on the main run loop that freezes all system input.
    private func openHIDManager() {
        guard let hidManager else { return }
        let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            dlog(String(format: "MX Master: IOHIDManagerOpen returned 0x%08x", openResult))
        }
    }

    /// Shows the Input Monitoring prompt off the main thread (`IOHIDRequestAccess` blocks until the user answers),
    /// then polls so access granted later in System Settings is picked up without relaunching.
    private func requestInputMonitoringAccess() {
        Task.detached(priority: .utility) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        guard inputMonitoringTimer == nil else { return }
        inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
                self.inputMonitoringTimer?.invalidate()
                self.inputMonitoringTimer = nil
                self.hasInputMonitoringAccess = true
                self.openHIDManager()
                // Force a fresh open + feature probe now that access is granted
                self.activeHIDDevice = nil
                self.refreshDeviceState()
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    public func openInputMonitoringSettings() {
        if !hasInputMonitoringAccess {
            requestInputMonitoringAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Scans IOHIDManager, IORegistry, and IOPowerSources to detect the MX Master mouse and query its telemetry.
    public func refreshDeviceState() {
        let registryBattery = Self.readSystemBatteryForLogitechMouse()
        let candidate = findBestLogitechHIDDevice()

        if let candidate {
            let wasDisconnected = !isConnected || activeHIDDevice !== candidate.device
            activeHIDDevice = candidate.device
            activeDeviceIndex = candidate.deviceIndex
            isConnected = true

            if wasDisconnected {
                featureTable.removeAll()
                pressedDivertedCIDs.removeAll()
                releaseGestureHoldIfNeeded()
                // Skip opening without access: the open would trigger a blocking TCC prompt on the main thread.
                if hasInputMonitoringAccess {
                    let openResult = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
                    if openResult != kIOReturnSuccess {
                        dlog(String(format: "MX Master: IOHIDDeviceOpen returned 0x%08x", openResult))
                    }
                    probeHIDPPFeatures()
                }
            } else {
                requestBatteryFromHIDPP()
                requestDPIFromHIDPP()
                requestSmartShiftFromHIDPP()
            }

            let resolvedName = candidate.name.isEmpty ? "MX Master 4" : candidate.name
            let mergedBattery = snapshot.batteryPercent ?? registryBattery?.percentage
            let mergedCharging = registryBattery?.isCharging ?? snapshot.isCharging

            snapshot = MXMasterSnapshot(
                deviceName: resolvedName,
                productID: candidate.productID,
                transport: candidate.transport,
                batteryPercent: mergedBattery,
                isCharging: mergedCharging,
                hidppConnected: !featureTable.isEmpty,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: snapshot.reportedDPI ?? config.dpi,
                reportedWheelMode: snapshot.reportedWheelMode ?? config.wheelMode,
                reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled ?? config.smartShiftEnabled,
                reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold ?? config.smartShiftThreshold
            )
            if !hasInputMonitoringAccess {
                lastStatusMessage = "Input Monitoring permission needed to talk to the mouse"
            } else if featureTable.isEmpty {
                lastStatusMessage = "Connected via \(candidate.transport.rawValue) — waiting for HID++ reply…"
            } else {
                lastStatusMessage = "Connected via \(candidate.transport.rawValue)"
            }
        } else if let registryBattery {
            // Connected via Bluetooth LE where macOS HID event driver owns the device
            isConnected = true
            activeHIDDevice = nil
            snapshot = MXMasterSnapshot(
                deviceName: registryBattery.deviceName,
                productID: registryBattery.productID,
                transport: .bluetoothLE,
                batteryPercent: registryBattery.percentage,
                isCharging: registryBattery.isCharging,
                hidppConnected: false,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: config.dpi,
                reportedWheelMode: config.wheelMode,
                reportedSmartShiftEnabled: config.smartShiftEnabled,
                reportedSmartShiftThreshold: config.smartShiftThreshold
            )
            lastStatusMessage = "Connected via Bluetooth LE"
        } else {
            isConnected = false
            activeHIDDevice = nil
            featureTable.removeAll()
            snapshot = MXMasterSnapshot(
                deviceName: "MX Master 4",
                productID: 0,
                transport: .disconnected,
                batteryPercent: nil,
                isCharging: false,
                hidppConnected: false,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: nil,
                reportedWheelMode: nil,
                reportedSmartShiftEnabled: nil,
                reportedSmartShiftThreshold: nil
            )
            lastStatusMessage = "No MX Master detected (connect via Bluetooth or Logi Bolt)"
        }
    }

    private struct HIDCandidate {
        let device: IOHIDDevice
        let name: String
        let productID: Int
        let transport: MXConnectionTransport
        let deviceIndex: UInt8
        let score: Int
    }

    private func findBestLogitechHIDDevice() -> HIDCandidate? {
        guard let manager = hidManager,
              let devSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        var best: HIDCandidate?
        for device in devSet {
            let vendorID = Self.intProperty(kIOHIDVendorIDKey, of: device) ?? 0
            guard vendorID == HIDPPProtocol.logitechVendorID else { continue }

            let productID = Self.intProperty(kIOHIDProductIDKey, of: device) ?? 0
            let rawName = Self.stringProperty(kIOHIDProductKey, of: device) ?? ""
            let transportStr = (Self.stringProperty(kIOHIDTransportKey, of: device) ?? "").lowercased()
            let usagePage = Self.intProperty(kIOHIDPrimaryUsagePageKey, of: device) ?? 0
            let usage = Self.intProperty(kIOHIDPrimaryUsageKey, of: device) ?? 0

            // Exclude pure keyboards that aren't receivers or MX Master mice
            let lowerName = rawName.lowercased()
            if lowerName.contains("keyboard") || lowerName.contains("mx keys") {
                continue
            }

            let transport: MXConnectionTransport
            let deviceIndex: UInt8
            var score = 10

            if productID == HIDPPProtocol.boltReceiverProductID {
                transport = .logiBolt
                deviceIndex = 0x01 // First paired slot on Logi Bolt receiver
                score += 40
            } else if productID == HIDPPProtocol.unifyingReceiverProductID {
                transport = .unifying
                deviceIndex = 0x01
                score += 35
            } else if transportStr.contains("bluetooth") || transportStr.contains("ble") {
                transport = .bluetoothLE
                deviceIndex = 0xFF
                score += 50
            } else {
                transport = .usbWired
                deviceIndex = 0xFF
                score += 30
            }

            if lowerName.contains("mx master 4") {
                score += 100
            } else if lowerName.contains("mx master") {
                score += 80
            }

            // Prefer vendor-defined HID++ collection (0xFF00 or 0xFF43) for bidirectional feature reports
            if usagePage >= 0xFF00 {
                score += 60
            } else if usagePage == 0x01 && (usage == 0x02 || usage == 0x01) {
                score += 20
            }

            let displayName: String
            if lowerName.contains("mx master") {
                displayName = rawName
            } else if transport == .logiBolt || transport == .unifying {
                displayName = "MX Master 4"
            } else {
                displayName = rawName.isEmpty ? "MX Master 4" : rawName
            }

            let candidate = HIDCandidate(
                device: device,
                name: displayName,
                productID: productID,
                transport: transport,
                deviceIndex: deviceIndex,
                score: score
            )

            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }
        return best
    }

    private nonisolated static func intProperty(_ key: String, of device: IOHIDDevice) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private nonisolated static func stringProperty(_ key: String, of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    // MARK: - System Battery Fallback (IOPowerSources & IORegistry)

    private struct SystemMouseBattery {
        let deviceName: String
        let productID: Int
        let percentage: Int
        let isCharging: Bool
    }

    /// Reads Bluetooth LE / HID battery telemetry published to macOS IOPowerSources or IORegistry.
    private nonisolated static func readSystemBatteryForLogitechMouse() -> SystemMouseBattery? {
        // 1. Check IOPSCopyPowerSourcesInfo for accessory batteries (Bluetooth mice/trackpads)
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }
                let name = (desc[kIOPSNameKey as String] as? String) ?? ""
                let lower = name.lowercased()
                let transport = ((desc[kIOPSTransportTypeKey as String] as? String) ?? "").lowercased()
                guard lower.contains("mx master") || lower.contains("logi") || (transport.contains("bluetooth") && lower.contains("mouse")) else {
                    continue
                }
                if let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int, (1...100).contains(capacity) {
                    let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
                    let displayName = lower.contains("mx master") ? name : "MX Master 4"
                    return SystemMouseBattery(deviceName: displayName, productID: 0, percentage: capacity, isCharging: isCharging)
                }
            }
        }

        // 2. Check IORegistry for IOHIDDevice / AppleDeviceManagementHIDEventService nodes with VendorID 0x046D and BatteryPercent
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let vendor = dict["VendorID"] as? Int ?? 0
            let product = dict["Product"] as? String ?? ""
            let lower = product.lowercased()
            guard vendor == HIDPPProtocol.logitechVendorID || lower.contains("mx master") else {
                continue
            }
            if lower.contains("keyboard") || lower.contains("mx keys") {
                continue
            }
            if let percent = dict["BatteryPercent"] as? Int, (1...100).contains(percent) {
                let productID = dict["ProductID"] as? Int ?? 0
                let displayName = lower.contains("mx master") ? product : "MX Master 4"
                return SystemMouseBattery(deviceName: displayName, productID: productID, percentage: percent, isCharging: false)
            }
        }

        return nil
    }

    // MARK: - HID++ 2.0 Transport & Feature Negotiation

    private func sendHIDPPPacket(_ packet: [UInt8]) {
        guard let device = activeHIDDevice, !packet.isEmpty else { return }
        let reportID = CFIndex(packet[0])
        packet.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, buf.count)
            if result != kIOReturnSuccess {
                dlog(String(format: "MX Master: HID++ SetReport failed 0x%08x", result))
            }
        }
    }

    /// Resolves feature indices for UnifiedBattery, AdjustableDPI, SmartShift, and ReprogControlsV4.
    private func probeHIDPPFeatures() {
        let featuresToProbe: [UInt16] = [
            HIDPPProtocol.featureUnifiedBattery,
            HIDPPProtocol.featureBatteryStatus,
            HIDPPProtocol.featureAdjustableDPI,
            HIDPPProtocol.featureSmartShiftEnhanced,
            HIDPPProtocol.featureSmartShift,
            HIDPPProtocol.featureReprogControlsV4
        ]
        for (idx, featureID) in featuresToProbe.enumerated() {
            // Encode the feature lookup slot in the softwareID nibble (1...6) so replies map back unambiguously.
            let swID = UInt8(idx + 1)
            let packet = HIDPPProtocol.makeLongPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: 0x00,
                functionID: 0x00,
                swID: swID,
                params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
            )
            sendHIDPPPacket(packet)
        }
    }

    private func handleIncomingHIDReport(reportID: UInt8, bytes: [UInt8]) {
        var raw = bytes
        if !raw.isEmpty && raw[0] != reportID && (reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID) {
            raw.insert(reportID, at: 0)
        }
        guard let norm = HIDPPProtocol.normalizeReport(raw), !HIDPPProtocol.isErrorResponse(norm) else {
            return
        }

        let featureIndex = norm[2]
        let swID = norm[3] & 0x0F

        // 1. Check if this is an IRoot (0x0000) feature lookup response
        if featureIndex == 0x00, let resolvedIndex = HIDPPProtocol.parseFeatureIndexReply(norm) {
            let probedFeatures: [UInt16] = [
                HIDPPProtocol.featureUnifiedBattery,
                HIDPPProtocol.featureBatteryStatus,
                HIDPPProtocol.featureAdjustableDPI,
                HIDPPProtocol.featureSmartShiftEnhanced,
                HIDPPProtocol.featureSmartShift,
                HIDPPProtocol.featureReprogControlsV4
            ]
            let slot = Int(swID) - 1
            if probedFeatures.indices.contains(slot) {
                let featureID = probedFeatures[slot]
                featureTable[featureID] = resolvedIndex
                onFeatureResolved(featureID: featureID, index: resolvedIndex)
            }
            return
        }

        // 2. UnifiedBattery (0x1004) or BatteryStatus (0x1000)
        if let unifiedIdx = featureTable[HIDPPProtocol.featureUnifiedBattery], featureIndex == unifiedIdx,
           let reading = HIDPPProtocol.parseBatteryReply(norm, expectedFeatureIndex: unifiedIdx, isUnifiedBattery: true) {
            updateSnapshotBattery(reading)
            return
        }
        if let legacyIdx = featureTable[HIDPPProtocol.featureBatteryStatus], featureIndex == legacyIdx,
           let reading = HIDPPProtocol.parseBatteryReply(norm, expectedFeatureIndex: legacyIdx, isUnifiedBattery: false) {
            updateSnapshotBattery(reading)
            return
        }

        // 3. AdjustableDPI (0x2201)
        if let dpiIdx = featureTable[HIDPPProtocol.featureAdjustableDPI], featureIndex == dpiIdx,
           let reportedDPI = HIDPPProtocol.parseSensorDPIReply(norm, expectedFeatureIndex: dpiIdx) {
            snapshot = MXMasterSnapshot(
                deviceName: snapshot.deviceName,
                productID: snapshot.productID,
                transport: snapshot.transport,
                batteryPercent: snapshot.batteryPercent,
                isCharging: snapshot.isCharging,
                hidppConnected: true,
                minDPI: snapshot.minDPI,
                maxDPI: snapshot.maxDPI,
                dpiStep: snapshot.dpiStep,
                reportedDPI: reportedDPI,
                reportedWheelMode: snapshot.reportedWheelMode,
                reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
                reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
            )
            return
        }

        // 4. SmartShift (0x2111 or 0x2110)
        if let feature = smartShiftFeature, featureIndex == feature.index {
            // Only getRatchetControlMode replies carry the mode; ignore set acknowledgements and capabilities.
            let functionID = norm[3] >> 4
            guard functionID == (feature.isEnhanced ? 0x01 : 0x00) else { return }
        }
        if let feature = smartShiftFeature, featureIndex == feature.index,
           let reading = HIDPPProtocol.parseSmartShiftReply(norm, expectedFeatureIndex: feature.index) {
            snapshot = MXMasterSnapshot(
                deviceName: snapshot.deviceName,
                productID: snapshot.productID,
                transport: snapshot.transport,
                batteryPercent: snapshot.batteryPercent,
                isCharging: snapshot.isCharging,
                hidppConnected: true,
                minDPI: snapshot.minDPI,
                maxDPI: snapshot.maxDPI,
                dpiStep: snapshot.dpiStep,
                reportedDPI: snapshot.reportedDPI,
                reportedWheelMode: reading.wheelMode,
                reportedSmartShiftEnabled: reading.smartShiftEnabled,
                reportedSmartShiftThreshold: reading.threshold
            )
            return
        }

        // 5. Diverted Gesture/Thumb Button Events (0x1B04)
        if let reprogIdx = featureTable[HIDPPProtocol.featureReprogControlsV4], featureIndex == reprogIdx,
           let pressedCIDs = HIDPPProtocol.parseDivertedButtonsEvent(norm, expectedFeatureIndex: reprogIdx) {
            let pressed = Set(pressedCIDs)
            let previous = pressedDivertedCIDs
            pressedDivertedCIDs = pressed
            for cid in pressed.subtracting(previous) {
                handleDivertedControl(cid, isDown: true)
            }
            for cid in previous.subtracting(pressed) {
                handleDivertedControl(cid, isDown: false)
            }
        }
    }

    private func onFeatureResolved(featureID: UInt16, index: UInt8) {
        switch featureID {
        case HIDPPProtocol.featureUnifiedBattery, HIDPPProtocol.featureBatteryStatus:
            requestBatteryFromHIDPP()
        case HIDPPProtocol.featureAdjustableDPI:
            sendDPIToHardware(config.dpi)
        case HIDPPProtocol.featureSmartShiftEnhanced, HIDPPProtocol.featureSmartShift:
            sendSmartShiftToHardware(
                wheelMode: config.wheelMode,
                smartShiftEnabled: config.smartShiftEnabled,
                threshold: config.smartShiftThreshold
            )
        case HIDPPProtocol.featureReprogControlsV4:
            configureDivertedButtonsIfNeeded()
        default:
            break
        }
    }

    private func updateSnapshotBattery(_ reading: HIDPPProtocol.BatteryReading) {
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: reading.percentage,
            isCharging: reading.isCharging,
            hidppConnected: true,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: snapshot.reportedDPI,
            reportedWheelMode: snapshot.reportedWheelMode,
            reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
            reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
        )
    }

    func requestBatteryFromHIDPP() {
        if let idx = featureTable[HIDPPProtocol.featureUnifiedBattery] {
            sendHIDPPPacket(HIDPPProtocol.getUnifiedBatteryStatusPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        } else if let idx = featureTable[HIDPPProtocol.featureBatteryStatus] {
            sendHIDPPPacket(HIDPPProtocol.getLegacyBatteryStatusPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        }
    }

    private func requestDPIFromHIDPP() {
        if let idx = featureTable[HIDPPProtocol.featureAdjustableDPI] {
            sendHIDPPPacket(HIDPPProtocol.getSensorDPIPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        }
    }

    func sendDPIToHardware(_ dpi: Int) {
        let clamped = MXMasterConfig.clampedDPI(dpi)
        if let idx = featureTable[HIDPPProtocol.featureAdjustableDPI] {
            sendHIDPPPacket(HIDPPProtocol.setSensorDPIPacket(deviceIndex: activeDeviceIndex, featureIndex: idx, dpi: clamped))
        }
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: snapshot.batteryPercent,
            isCharging: snapshot.isCharging,
            hidppConnected: snapshot.hidppConnected,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: clamped,
            reportedWheelMode: snapshot.reportedWheelMode,
            reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
            reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
        )
    }

    /// Resolved SmartShift feature index, preferring Enhanced (`0x2111`, used by MX Master 3S / 4) over `0x2110`.
    private var smartShiftFeature: (index: UInt8, isEnhanced: Bool)? {
        if let idx = featureTable[HIDPPProtocol.featureSmartShiftEnhanced] { return (idx, true) }
        if let idx = featureTable[HIDPPProtocol.featureSmartShift] { return (idx, false) }
        return nil
    }

    private func requestSmartShiftFromHIDPP() {
        guard let feature = smartShiftFeature else { return }
        sendHIDPPPacket(HIDPPProtocol.getSmartShiftPacket(
            deviceIndex: activeDeviceIndex,
            featureIndex: feature.index,
            isEnhanced: feature.isEnhanced
        ))
    }

    func sendSmartShiftToHardware(wheelMode: MXWheelMode, smartShiftEnabled: Bool, threshold: Int) {
        if let feature = smartShiftFeature {
            let packet = HIDPPProtocol.setSmartShiftPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: feature.index,
                isEnhanced: feature.isEnhanced,
                wheelMode: wheelMode,
                smartShiftEnabled: smartShiftEnabled,
                threshold: threshold
            )
            sendHIDPPPacket(packet)
        }
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: snapshot.batteryPercent,
            isCharging: snapshot.isCharging,
            hidppConnected: snapshot.hidppConnected,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: snapshot.reportedDPI,
            reportedWheelMode: wheelMode,
            reportedSmartShiftEnabled: smartShiftEnabled,
            reportedSmartShiftThreshold: threshold
        )
    }

    func configureDivertedButtonsIfNeeded() {
        guard let idx = featureTable[HIDPPProtocol.featureReprogControlsV4] else { return }
        let diversions: [(UInt16, Bool)] = [
            (HIDPPProtocol.cidGestureThumbButton, config.gesturesEnabled || config.gestureButtonClickAction != .systemDefault),
            (HIDPPProtocol.cidModeShiftButton, config.modeShiftButtonAction != .systemDefault),
            (HIDPPProtocol.cidHapticPanelButton, config.hapticPanelButtonAction != .systemDefault)
        ]
        for (cid, diverted) in diversions {
            sendHIDPPPacket(HIDPPProtocol.setControlDivertedPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: idx,
                controlID: cid,
                diverted: diverted
            ))
        }
    }

    /// Routes a press/release edge of a HID++-diverted control to its configured action.
    private func handleDivertedControl(_ cid: UInt16, isDown: Bool) {
        switch cid {
        case HIDPPProtocol.cidGestureThumbButton:
            handleDivertedGestureButtonState(isDown: isDown)
        case HIDPPProtocol.cidModeShiftButton:
            if isDown { performButtonAction(config.modeShiftButtonAction) }
        case HIDPPProtocol.cidHapticPanelButton:
            if isDown { performButtonAction(config.hapticPanelButtonAction) }
        default:
            break
        }
    }
}
