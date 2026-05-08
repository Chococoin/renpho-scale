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

    // MARK: - CBPeripheralDelegate (rest in Task 10)
}
