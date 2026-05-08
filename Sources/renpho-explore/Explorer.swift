import Foundation
import CoreBluetooth
import RenphoBLE

// MARK: - Data types

enum ExplorerEvent {
    case scanStarted
    case peripheralFound(name: String, identifier: UUID)
    case connecting
    case connected
    case serviceDiscovered(uuid: CBUUID)
    case characteristicDiscovered(service: CBUUID, uuid: CBUUID, properties: CBCharacteristicProperties)
    case readSucceeded(characteristic: CBUUID, value: Data)
    case readFailed(characteristic: CBUUID, error: Error)
    case notifySubscribed(characteristic: CBUUID)
    case notification(characteristic: CBUUID, value: Data)
    case ready
    case disconnected(error: Error?)
}

enum ExplorerError: Error {
    case scanTimeoutNoMatch
    case connectFailed(Error?)
}

// MARK: - BLEExplorer

final class BLEExplorer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var nameFilter: String = ""

    private var continuation: AsyncStream<ExplorerEvent>.Continuation?

    // Phase-specific continuations (one-shot)
    private var powerOnContinuation: CheckedContinuation<Void, Error>?
    private var foundContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // Discovery / read / subscribe progress tracking, used to emit `.ready`.
    private var pendingCharDiscoveries: Int = 0   // services awaiting char discovery
    private var pendingReads: Set<CBUUID> = []    // chars where readValue was called and we haven't gotten the response
    private var pendingSubscribes: Set<CBUUID> = []  // chars where setNotifyValue(true) was called and we haven't gotten the confirmation
    private var hasDiscoveredServices = false
    private var hasEmittedReady = false

    /// Escanea, conecta al primer peripheral cuyo nombre matche `nameFilter`,
    /// hace discovery completo, lee todas las readable, y se suscribe a todas
    /// las notify. Devuelve un AsyncStream que emite ExplorerEvent hasta que
    /// `stop()` o el peripheral se desconecte.
    /// Lanza errores tempranos en cada fase: power state, scan, connect.
    func run(
        nameFilter: String,
        scanTimeout: TimeInterval,
        connectTimeout: TimeInterval
    ) async throws -> AsyncStream<ExplorerEvent> {
        self.nameFilter = nameFilter

        let (stream, cont) = AsyncStream<ExplorerEvent>.makeStream()
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
            // Watchdog timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(scanTimeout * 1_000_000_000))
                guard let self else { return }
                guard let cont = self.foundContinuation else { return }
                self.foundContinuation = nil
                self.central?.stopScan()
                cont.resume(throwing: ExplorerError.scanTimeoutNoMatch)
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
                cont.resume(throwing: ExplorerError.connectFailed(nil))
            }
        }
        cont.yield(.connected)

        // Phase D: kick off discovery; the rest of the events come via the stream
        p.discoverServices(nil)

        return stream
    }

    /// Inicia el cierre limpio: desconecta el peripheral. La finalización del
    /// stream ocurre vía `didDisconnectPeripheral`.
    func stop() {
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Helpers

    private func checkAndEmitReadyIfDone() {
        guard hasDiscoveredServices,
              !hasEmittedReady,
              pendingCharDiscoveries == 0,
              pendingReads.isEmpty,
              pendingSubscribes.isEmpty else { return }
        hasEmittedReady = true
        continuation?.yield(.ready)
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
        cont.resume(throwing: ExplorerError.connectFailed(error))
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
        guard let services = peripheral.services else {
            hasDiscoveredServices = true
            checkAndEmitReadyIfDone()
            return
        }
        hasDiscoveredServices = true
        pendingCharDiscoveries = services.count
        for service in services {
            continuation?.yield(.serviceDiscovered(uuid: service.uuid))
            peripheral.discoverCharacteristics(nil, for: service)
        }
        checkAndEmitReadyIfDone()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if pendingCharDiscoveries > 0 { pendingCharDiscoveries -= 1 }
        guard let chars = service.characteristics else {
            checkAndEmitReadyIfDone()
            return
        }
        for char in chars {
            continuation?.yield(.characteristicDiscovered(
                service: service.uuid,
                uuid: char.uuid,
                properties: char.properties
            ))
        }
        for char in chars {
            if char.properties.contains(.read) {
                pendingReads.insert(char.uuid)
                peripheral.readValue(for: char)
            }
            if char.properties.contains(.notify) {
                pendingSubscribes.insert(char.uuid)
                peripheral.setNotifyValue(true, for: char)
            }
        }
        checkAndEmitReadyIfDone()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Distinguish read response vs notification by tracked state
        if pendingReads.contains(characteristic.uuid) {
            pendingReads.remove(characteristic.uuid)
            if let error = error {
                continuation?.yield(.readFailed(characteristic: characteristic.uuid, error: error))
            } else {
                // Some readable chars return zero-length values (e.g., empty strings).
                // Emit success with empty Data rather than silently dropping the event.
                continuation?.yield(.readSucceeded(
                    characteristic: characteristic.uuid,
                    value: characteristic.value ?? Data()
                ))
            }
            checkAndEmitReadyIfDone()
        } else {
            // Notification (or post-subscribe value update)
            if let value = characteristic.value, error == nil {
                continuation?.yield(.notification(characteristic: characteristic.uuid, value: value))
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        pendingSubscribes.remove(characteristic.uuid)
        if error == nil && characteristic.isNotifying {
            continuation?.yield(.notifySubscribed(characteristic: characteristic.uuid))
        }
        checkAndEmitReadyIfDone()
    }
}
