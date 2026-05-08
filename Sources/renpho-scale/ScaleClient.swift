import Foundation
import CoreBluetooth
import RenphoBLE

// MARK: - Public types

enum ScaleEvent {
    case scanStarted
    case peripheralFound(name: String, identifier: UUID)
    case connecting
    case connected
    case metadataRead(field: MetadataField, data: Data)
    case metadataReadFailed(field: MetadataField, error: Error)
    case subscribed
    case rawNotification(value: Data)
    case disconnected(error: Error?)
}

enum MetadataField: String {
    case manufacturerName, modelNumber, serialNumber
    case firmwareRevision, hardwareRevision, softwareRevision
    case systemId
    case batteryLevel
}

enum ScaleClientError: Error {
    case scanTimeoutNoMatch
    case connectFailed(Error?)
}

// MARK: - ScaleClient

final class ScaleClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var nameFilter: String = ""

    private var continuation: AsyncStream<ScaleEvent>.Continuation?

    // One-shot continuations per phase
    private var powerOnContinuation: CheckedContinuation<Void, Error>?
    private var foundContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // Tracking pending operations to know when to emit .subscribed
    private var pendingMetadataReads: Set<CBUUID> = []
    private var hasSubscribed = false

    func run(
        nameFilter: String,
        scanTimeout: TimeInterval = 15,
        connectTimeout: TimeInterval = 10
    ) async throws -> AsyncStream<ScaleEvent> {
        self.nameFilter = nameFilter

        let (stream, cont) = AsyncStream<ScaleEvent>.makeStream()
        self.continuation = cont

        // Phase A: power state
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.powerOnContinuation = c
            self.central = CBCentralManager(delegate: self, queue: nil)
        }

        // Phase B: scan
        cont.yield(.scanStarted)
        let p: CBPeripheral = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            self.foundContinuation = c
            self.central.scanForPeripherals(withServices: nil, options: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(scanTimeout * 1_000_000_000))
                guard let self else { return }
                guard let cont = self.foundContinuation else { return }
                self.foundContinuation = nil
                self.central?.stopScan()
                cont.resume(throwing: ScaleClientError.scanTimeoutNoMatch)
            }
        }
        self.peripheral = p
        p.delegate = self
        cont.yield(.peripheralFound(name: p.name ?? "<unnamed>", identifier: p.identifier))

        // Phase C: connect
        cont.yield(.connecting)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.connectContinuation = c
            self.central.connect(p, options: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
                guard let self else { return }
                guard let cont = self.connectContinuation else { return }
                self.connectContinuation = nil
                self.central?.cancelPeripheralConnection(p)
                cont.resume(throwing: ScaleClientError.connectFailed(nil))
            }
        }
        cont.yield(.connected)

        // Phase D: discovery (Task 10 hook — by now this is a stub: peripheral disconnects soon)
        // For now, just kick off discoverServices(nil) so the peripheral doesn't immediately drop.
        // Task 10 swaps this for directed discovery.
        p.discoverServices([RenphoUUIDs.measurementService, RenphoUUIDs.dis, RenphoUUIDs.battery])

        return stream
    }

    func stop() {
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let cont = powerOnContinuation else { return }
        powerOnContinuation = nil
        switch central.state {
        case .poweredOn:
            cont.resume()
        case .unauthorized:
            cont.resume(throwing: BLEPowerError.unauthorized)
        case .poweredOff:
            cont.resume(throwing: BLEPowerError.poweredOff)
        case .unsupported:
            cont.resume(throwing: BLEPowerError.unsupported)
        default:
            cont.resume(throwing: BLEPowerError.unsupported)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard !name.isEmpty,
              name.lowercased().contains(nameFilter.lowercased()) else { return }
        guard let cont = foundContinuation else { return }
        foundContinuation = nil
        central.stopScan()
        cont.resume(returning: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume(throwing: ScaleClientError.connectFailed(error))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        continuation?.yield(.disconnected(error: error))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        // Map service UUID → expected characteristics list
        let charsForService: [CBUUID: [CBUUID]] = [
            RenphoUUIDs.measurementService: [RenphoUUIDs.measurementChar],
            RenphoUUIDs.dis: [
                RenphoUUIDs.manufacturerName,
                RenphoUUIDs.modelNumber,
                RenphoUUIDs.serialNumber,
                RenphoUUIDs.hardwareRevision,
                RenphoUUIDs.firmwareRevision,
                RenphoUUIDs.softwareRevision,
                RenphoUUIDs.systemId
            ],
            RenphoUUIDs.battery: [RenphoUUIDs.batteryLevel]
        ]

        for service in services {
            if let expected = charsForService[service.uuid] {
                peripheral.discoverCharacteristics(expected, for: service)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }

        for char in chars {
            // Subscribe a la char de measurement
            if char.uuid == RenphoUUIDs.measurementChar {
                peripheral.setNotifyValue(true, for: char)
                continue
            }

            // Reads de metadata (DIS + Battery)
            if let field = metadataField(for: char.uuid) {
                pendingMetadataReads.insert(char.uuid)
                peripheral.readValue(for: char)
                _ = field   // referenced when the read returns
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Notification del char de measurement
        if characteristic.uuid == RenphoUUIDs.measurementChar
           && pendingMetadataReads.contains(characteristic.uuid) == false {
            // Es notification — sólo emit si ya nos subscribimos (puede llegar valor inicial pre-subscribe)
            if let value = characteristic.value, error == nil {
                continuation?.yield(.rawNotification(value: value))
            }
            return
        }

        // Read response de metadata
        if pendingMetadataReads.contains(characteristic.uuid),
           let field = metadataField(for: characteristic.uuid) {
            pendingMetadataReads.remove(characteristic.uuid)
            if let error = error {
                continuation?.yield(.metadataReadFailed(field: field, error: error))
            } else if let value = characteristic.value {
                continuation?.yield(.metadataRead(field: field, data: value))
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == RenphoUUIDs.measurementChar else { return }
        if error == nil && characteristic.isNotifying && !hasSubscribed {
            hasSubscribed = true
            continuation?.yield(.subscribed)
        }
    }

    // MARK: - Helpers

    private func metadataField(for uuid: CBUUID) -> MetadataField? {
        switch uuid {
        case RenphoUUIDs.manufacturerName: return .manufacturerName
        case RenphoUUIDs.modelNumber:      return .modelNumber
        case RenphoUUIDs.serialNumber:     return .serialNumber
        case RenphoUUIDs.firmwareRevision: return .firmwareRevision
        case RenphoUUIDs.hardwareRevision: return .hardwareRevision
        case RenphoUUIDs.softwareRevision: return .softwareRevision
        case RenphoUUIDs.systemId:         return .systemId
        case RenphoUUIDs.batteryLevel:     return .batteryLevel
        default:                            return nil
        }
    }
}
