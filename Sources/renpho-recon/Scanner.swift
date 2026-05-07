import Foundation
import CoreBluetooth

struct AdvertisementFrame {
    let timestamp: Date
    let identifier: UUID
    let name: String?
    let rssi: Int
    let manufacturerData: Data?
    let serviceUUIDs: [CBUUID]
    let serviceData: [CBUUID: Data]
}

enum ScannerError: Error {
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnsupported
    case unknownState
}

final class BLEScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var continuation: AsyncStream<AdvertisementFrame>.Continuation?
    private var startContinuation: CheckedContinuation<Void, Error>?

    /// Crea el central manager, espera a que reporte estado, y arranca el escaneo.
    /// Devuelve un AsyncStream que finaliza cuando se llama a `stop()`.
    func start() async throws -> AsyncStream<AdvertisementFrame> {
        let (stream, cont) = AsyncStream<AdvertisementFrame>.makeStream()
        self.continuation = cont

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.startContinuation = c
            self.central = CBCentralManager(delegate: self, queue: nil)
        }

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        return stream
    }

    func stop() {
        central?.stopScan()
        continuation?.finish()
        continuation = nil
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        switch central.state {
        case .poweredOn:
            cont.resume()
        case .unauthorized:
            cont.resume(throwing: ScannerError.bluetoothUnauthorized)
        case .poweredOff:
            cont.resume(throwing: ScannerError.bluetoothPoweredOff)
        case .unsupported:
            cont.resume(throwing: ScannerError.bluetoothUnsupported)
        default:
            cont.resume(throwing: ScannerError.unknownState)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)

        let frame = AdvertisementFrame(
            timestamp: Date(),
            identifier: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            manufacturerData: mfgData,
            serviceUUIDs: serviceUUIDs,
            serviceData: serviceData
        )
        continuation?.yield(frame)
    }
}
