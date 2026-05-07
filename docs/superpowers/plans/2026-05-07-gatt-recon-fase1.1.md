# Renpho GATT Recon Fase 1.1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir `renpho-explore`, un segundo ejecutable Swift en el repo `renpho-scale` que se conecta vía GATT al Renpho Elis 1C, descubre todo su árbol de services y characteristics, lee las readable, se suscribe a las notify, y vuelca todos los eventos a consola y JSONL durante una pesada.

**Architecture:** Nuevo target ejecutable en el SwiftPM existente. Tres archivos fuente: `main.swift` (parseo de args y orquestación), `Explorer.swift` (clase única `BLEExplorer` que implementa `CBCentralManagerDelegate` + `CBPeripheralDelegate` y expone un `AsyncStream<ExplorerEvent>`), `EventLogger.swift` (pretty-print + JSONL append). Sin dependencias externas. Reusa el `Info.plist` ya embebido (permiso de Bluetooth ya aprobado por el usuario).

**Tech Stack:** Swift 5.9+, CoreBluetooth, Foundation. macOS 11+. Sin tests automatizados (deferidos a 1.2, igual que se hizo en 1.0).

**Spec de referencia:** `docs/superpowers/specs/2026-05-07-gatt-recon-fase1.1-design.md`

---

## File Structure

| Archivo | Estado | Responsabilidad |
|---------|--------|-----------------|
| `Package.swift` | Modify | Agregar segundo `executableTarget` `renpho-explore` con su Info.plist embebido. |
| `Sources/renpho-explore/main.swift` | Create | Entry point top-level async, parseo de args, orquestación de Explorer + EventLogger, exit codes, summary. |
| `Sources/renpho-explore/Explorer.swift` | Create | Tipos `ExplorerEvent`, `ExplorerError`. Clase `BLEExplorer` (delegate de CBCentralManager y CBPeripheral). Expone `run(...)` async que devuelve `AsyncStream<ExplorerEvent>`. |
| `Sources/renpho-explore/EventLogger.swift` | Create | Renderiza eventos a consola y opcionalmente a JSONL. Define la extensión local `ISO8601DateFormatter.fractional` (duplicada del target `renpho-recon` por decisión YAGNI documentada en el spec). |
| `docs/superpowers/notes/2026-05-07-gatt-results.md` | Create (Task 5) | Notas técnicas con el árbol GATT descubierto y la decisión de si la 1.2 puede ser passive+read o necesita writes. |

---

## Task 1: Agregar segundo target al paquete + stub

**Files:**
- Modify: `~/Projects/renpho-scale/Package.swift`
- Create: `~/Projects/renpho-scale/Sources/renpho-explore/main.swift` (stub)

- [ ] **Step 1: Reemplazar `Package.swift` completo**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "renpho-scale",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "renpho-recon",
            path: "Sources/renpho-recon",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "renpho-explore",
            path: "Sources/renpho-explore",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
```

- [ ] **Step 2: Crear stub `Sources/renpho-explore/main.swift`**

```swift
import Foundation

print("renpho-explore stub")
```

- [ ] **Step 3: Verificar build de ambos targets**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds. Two binaries produced: `.build/debug/renpho-recon` and `.build/debug/renpho-explore`.

- [ ] **Step 4: Verificar Info.plist embebido en el nuevo binario**

Run: `otool -s __TEXT __info_plist .build/debug/renpho-explore | tail -10`
Expected: hex dump non-empty, contiene strings `NSBluetoothAlwaysUsageDescription` y `dev.choco.renpho-recon`.

- [ ] **Step 5: Smoke test del stub**

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore`
Expected: prints `renpho-explore stub` and exits 0.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/renpho-scale
git add Package.swift Sources/renpho-explore/
git commit -m "feat: agregar segundo target renpho-explore con Info.plist embebido"
```

---

## Task 2: Implementar `Explorer.swift`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-explore/Explorer.swift`

- [ ] **Step 1: Crear `Explorer.swift` completo**

```swift
import Foundation
import CoreBluetooth

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
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnsupported
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
            cont.resume(throwing: ExplorerError.bluetoothUnauthorized)
        case .poweredOff:
            cont.resume(throwing: ExplorerError.bluetoothPoweredOff)
        case .unsupported:
            cont.resume(throwing: ExplorerError.bluetoothUnsupported)
        default:
            cont.resume(throwing: ExplorerError.bluetoothUnsupported)
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
            } else if let value = characteristic.value {
                continuation?.yield(.readSucceeded(characteristic: characteristic.uuid, value: value))
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
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: ambos targets compilan sin warnings sobre código del proyecto.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-explore/Explorer.swift
git commit -m "feat: BLEExplorer con scan, connect, discovery, reads y subscribe"
```

---

## Task 3: Implementar `EventLogger.swift`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-explore/EventLogger.swift`

- [ ] **Step 1: Crear `EventLogger.swift` completo**

```swift
import Foundation
import CoreBluetooth

/// Loggea ExplorerEvent a consola y opcionalmente a JSONL.
/// Acumula contadores para el summary final.
final class EventLogger {

    private let consoleVerbose: Bool
    private let jsonlHandle: FileHandle?

    // Counters for summary
    private(set) var serviceCount = 0
    private(set) var charCounts: (read: Int, write: Int, notify: Int) = (0, 0, 0)
    private(set) var readsOk = 0
    private(set) var readsFailed = 0
    private(set) var notificationsByChar: [CBUUID: Int] = [:]

    init(verbose: Bool, outputPath: String?) throws {
        self.consoleVerbose = verbose
        if let outputPath = outputPath {
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else {
                throw EventLoggerError.cannotOpen(path: outputPath)
            }
            try h.seekToEnd()
            self.jsonlHandle = h
        } else {
            self.jsonlHandle = nil
        }
    }

    func log(_ event: ExplorerEvent) {
        // Console
        let consoleLine = consoleString(for: event)
        print(consoleLine)

        // Counters
        updateCounters(for: event)

        // JSONL
        guard let handle = jsonlHandle else { return }
        let dict = jsonDict(for: event)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func close() {
        try? jsonlHandle?.close()
    }

    func printSummary() {
        print("")
        print("--- Summary ---")
        print("Services: \(serviceCount)")
        print("Characteristics: \(charCounts.read) read, \(charCounts.write) write, \(charCounts.notify) notify")
        print("Reads: \(readsOk) succeeded, \(readsFailed) failed")
        let totalNotifications = notificationsByChar.values.reduce(0, +)
        if totalNotifications > 0 {
            let breakdown = notificationsByChar
                .map { "\($0.key.uuidString.lowercased())=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            print("Notifications: \(totalNotifications) total (\(breakdown))")
        } else {
            print("Notifications: 0")
        }
    }

    // MARK: - Console formatting

    private func consoleString(for event: ExplorerEvent) -> String {
        let ts = ConsoleTime.string(from: Date())
        switch event {
        case .scanStarted:
            return "[\(ts)] scan started"
        case .peripheralFound(let name, let id):
            return "[\(ts)] found \(name) (\(String(id.uuidString.prefix(8))))"
        case .connecting:
            return "[\(ts)] connecting..."
        case .connected:
            return "[\(ts)] connected"
        case .serviceDiscovered(let uuid):
            return "[\(ts)] service \(uuid.uuidString.lowercased())"
        case .characteristicDiscovered(let svc, let char, let props):
            return "[\(ts)]   char \(char.uuidString.lowercased()) [\(propsToString(props))] (svc \(svc.uuidString.lowercased()))"
        case .readSucceeded(let char, let value):
            return "[\(ts)]   read \(char.uuidString.lowercased()) = \(hex(value))"
        case .readFailed(let char, let error):
            return "[\(ts)]   read \(char.uuidString.lowercased()) FAILED: \(error.localizedDescription)"
        case .notifySubscribed(let char):
            return "[\(ts)]   subscribed \(char.uuidString.lowercased())"
        case .notification(let char, let value):
            return "[\(ts)]   notify \(char.uuidString.lowercased()) = \(hex(value))"
        case .ready:
            return "\n--- Listening for notifications ---"
        case .disconnected(let error):
            if let e = error {
                return "[\(ts)] disconnected (error: \(e.localizedDescription))"
            } else {
                return "[\(ts)] disconnected"
            }
        }
    }

    // MARK: - JSON encoding

    private func jsonDict(for event: ExplorerEvent) -> [String: Any] {
        let ts = ISO8601DateFormatter.fractional.string(from: Date())
        var dict: [String: Any] = ["ts": ts]
        switch event {
        case .scanStarted:
            dict["type"] = "scan_started"
        case .peripheralFound(let name, let id):
            dict["type"] = "peripheral_found"
            dict["name"] = name
            dict["id"] = id.uuidString
        case .connecting:
            dict["type"] = "connecting"
        case .connected:
            dict["type"] = "connected"
        case .serviceDiscovered(let uuid):
            dict["type"] = "service_discovered"
            dict["service"] = uuid.uuidString.lowercased()
        case .characteristicDiscovered(let svc, let char, let props):
            dict["type"] = "char_discovered"
            dict["service"] = svc.uuidString.lowercased()
            dict["char"] = char.uuidString.lowercased()
            dict["props"] = propsToArray(props)
        case .readSucceeded(let char, let value):
            dict["type"] = "read_ok"
            dict["char"] = char.uuidString.lowercased()
            dict["value"] = hex(value)
        case .readFailed(let char, let error):
            dict["type"] = "read_failed"
            dict["char"] = char.uuidString.lowercased()
            dict["error"] = error.localizedDescription
        case .notifySubscribed(let char):
            dict["type"] = "notify_subscribed"
            dict["char"] = char.uuidString.lowercased()
        case .notification(let char, let value):
            dict["type"] = "notification"
            dict["char"] = char.uuidString.lowercased()
            dict["value"] = hex(value)
        case .ready:
            dict["type"] = "ready"
        case .disconnected(let error):
            dict["type"] = "disconnected"
            if let e = error {
                dict["error"] = e.localizedDescription
            }
        }
        return dict
    }

    // MARK: - Counters

    private func updateCounters(for event: ExplorerEvent) {
        switch event {
        case .serviceDiscovered:
            serviceCount += 1
        case .characteristicDiscovered(_, _, let props):
            if props.contains(.read) { charCounts.read += 1 }
            if props.contains(.write) || props.contains(.writeWithoutResponse) { charCounts.write += 1 }
            if props.contains(.notify) { charCounts.notify += 1 }
        case .readSucceeded:
            readsOk += 1
        case .readFailed:
            readsFailed += 1
        case .notification(let char, _):
            notificationsByChar[char, default: 0] += 1
        default:
            break
        }
    }

    // MARK: - Utils

    private func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private func propsToString(_ props: CBCharacteristicProperties) -> String {
        return propsToArray(props).joined(separator: ",")
    }

    private func propsToArray(_ props: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if props.contains(.read) { out.append("read") }
        if props.contains(.write) { out.append("write") }
        if props.contains(.writeWithoutResponse) { out.append("writeWithoutResponse") }
        if props.contains(.notify) { out.append("notify") }
        if props.contains(.indicate) { out.append("indicate") }
        if props.contains(.broadcast) { out.append("broadcast") }
        if props.contains(.notifyEncryptionRequired) { out.append("notifyEncryptionRequired") }
        if props.contains(.indicateEncryptionRequired) { out.append("indicateEncryptionRequired") }
        if props.contains(.extendedProperties) { out.append("extendedProperties") }
        if props.contains(.authenticatedSignedWrites) { out.append("authenticatedSignedWrites") }
        return out
    }
}

enum EventLoggerError: Error {
    case cannotOpen(path: String)
}

// MARK: - Time helpers

private enum ConsoleTime {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func string(from date: Date) -> String {
        return formatter.string(from: date)
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: ambos targets compilan sin warnings sobre código del proyecto. (Nota: si ya hay otra `ISO8601DateFormatter.fractional` en el target `renpho-recon`, NO genera conflicto — son targets distintos, cada uno con su propio módulo.)

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-explore/EventLogger.swift
git commit -m "feat: EventLogger con consola + JSONL + summary"
```

---

## Task 4: CLI orchestration en `main.swift`

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-explore/main.swift` (reemplazar stub)

- [ ] **Step 1: Reemplazar `main.swift` con implementación completa**

```swift
import Foundation

struct Args {
    var filter: String? = nil
    var duration: TimeInterval = 60
    var connectTimeout: TimeInterval = 10
    var verbose: Bool = false
    var out: String? = nil
}

func writeError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func parseArgs() -> Args {
    var args = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--filter":
            i += 1
            guard i < argv.count else {
                writeError("error: --filter requires a value")
                exit(1)
            }
            args.filter = argv[i]
        case "--duration":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --duration requires a positive number")
                exit(1)
            }
            args.duration = d
        case "--connect-timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --connect-timeout requires a positive number")
                exit(1)
            }
            args.connectTimeout = d
        case "--verbose":
            args.verbose = true
        case "--out":
            i += 1
            guard i < argv.count else {
                writeError("error: --out requires a path")
                exit(1)
            }
            args.out = argv[i]
        case "-h", "--help":
            print("usage: renpho-explore --filter <substring> [--duration <s>] [--connect-timeout <s>] [--verbose] [--out <path>]")
            exit(0)
        default:
            writeError("error: unknown arg \(a)")
            exit(1)
        }
        i += 1
    }
    return args
}

let args = parseArgs()

guard let filter = args.filter, !filter.isEmpty else {
    writeError("error: --filter is required")
    exit(1)
}

let logger: EventLogger
do {
    logger = try EventLogger(verbose: args.verbose, outputPath: args.out)
} catch {
    writeError("error: cannot open output file: \(error)")
    exit(4)
}
defer { logger.close() }

let explorer = BLEExplorer()
let stream: AsyncStream<ExplorerEvent>
do {
    stream = try await explorer.run(
        nameFilter: filter,
        scanTimeout: 15,
        connectTimeout: args.connectTimeout
    )
} catch ExplorerError.bluetoothUnauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch ExplorerError.bluetoothPoweredOff {
    writeError("error: Bluetooth is off. Please enable it.")
    exit(3)
} catch ExplorerError.bluetoothUnsupported {
    writeError("error: Bluetooth not supported on this Mac.")
    exit(3)
} catch ExplorerError.scanTimeoutNoMatch {
    writeError("error: scale not found within 15s. Is it active? Try waking it up.")
    exit(5)
} catch ExplorerError.connectFailed(let inner) {
    if let inner = inner {
        writeError("error: failed to connect: \(inner.localizedDescription)")
    } else {
        writeError("error: failed to connect: timeout after \(args.connectTimeout)s")
    }
    exit(6)
} catch {
    writeError("error: \(error)")
    exit(1)
}

// Listening: starts when we receive .ready; the duration timer also starts then.
var durationTimer: Task<Void, Never>?

for await event in stream {
    logger.log(event)
    if case .ready = event {
        durationTimer = Task { [duration = args.duration] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            explorer.stop()
        }
    }
}
durationTimer?.cancel()

logger.printSummary()
exit(0)
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: ambos targets compilan sin warnings sobre código del proyecto.

- [ ] **Step 3: Verificar `--help`**

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore --help`
Expected: imprime `usage: renpho-explore --filter <substring> [--duration <s>] [--connect-timeout <s>] [--verbose] [--out <path>]` y exit 0.

- [ ] **Step 4: Verificar manejo de --filter ausente**

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore; echo "exit=$?"`
Expected: stderr `error: --filter is required`, `exit=1`.

- [ ] **Step 5: Verificar manejo de duration inválida**

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore --filter foo --duration -3; echo "exit=$?"`
Expected: stderr `error: --duration requires a positive number`, `exit=1`.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-explore/main.swift
git commit -m "feat: orquestación CLI de renpho-explore con exit codes y summary"
```

---

## Task 5: Captura GATT real contra el Elis 1C + notas técnicas

Tarea manual con la balanza. Requiere usuario presente.

**Files:**
- Create: `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-07-gatt-results.md`

- [ ] **Step 1: Test de "scale not active"**

Asegurar que la balanza esté **dormida** (no la actives). Correr:

```
cd ~/Projects/renpho-scale && swift run renpho-explore --filter "R-A033" --duration 5; echo "exit=$?"
```

Expected: scan starts, después de ~15s sale con `error: scale not found within 15s. Is it active? Try waking it up.` y `exit=5`. Esto valida el path de timeout.

(Si la balanza se queda emitiendo aunque "dormida" — algunas Renpho lo hacen — saltea este step y pasalo a un check post-captura.)

- [ ] **Step 2: Captura activa con pesada completa**

Activá la balanza (subite y bajate brevemente). Inmediatamente correr:

```
cd ~/Projects/renpho-scale && swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt.jsonl
```

Cuando aparezca en consola la línea `--- Listening for notifications ---`:

1. Subite descalzo a la balanza.
2. Quedate quieto hasta ver el peso final en la pantalla.
3. Esperá ~5-10 segundos más (medición de impedancia).
4. Bajate. Si querés, repetí la pesada.

Dejá que el binario corra hasta los 90s o se desconecte solo.

- [ ] **Step 3: Verificar JSONL válido**

Run:
```
cd ~/Projects/renpho-scale && jq -c . gatt.jsonl | wc -l && \
echo "---tipos de eventos---" && \
jq -r '.type' gatt.jsonl | sort | uniq -c | sort -rn
```

Expected:
- Total > 5 líneas (al menos los eventos de lifecycle: scan_started, peripheral_found, connecting, connected, service_discovered, char_discovered, ready, disconnected, plus reads/notifies).
- La distribución de `.type` muestra los tipos esperados.

- [ ] **Step 4: Inspeccionar el árbol GATT**

Run:
```
cd ~/Projects/renpho-scale && \
echo "--- Services ---" && \
jq -r 'select(.type == "service_discovered") | .service' gatt.jsonl && \
echo "--- Characteristics ---" && \
jq -r 'select(.type == "char_discovered") | "\(.service)/\(.char) [\(.props | join(","))]"' gatt.jsonl && \
echo "--- Reads OK ---" && \
jq -r 'select(.type == "read_ok") | "\(.char) = \(.value)"' gatt.jsonl && \
echo "--- Notifications by char ---" && \
jq -r 'select(.type == "notification") | .char' gatt.jsonl | sort | uniq -c | sort -rn
```

Anotar para el archivo de notas (siguiente step):
- Lista de services con sus UUIDs.
- Por cada service, lista de chars con properties.
- Reads que dieron datos (ese hex puede ser info útil — modelo, batería, peso cacheado).
- Char que recibió la mayor cantidad de notifications durante la pesada — es el candidato a "stream de medición".

- [ ] **Step 5: Crear archivo de notas técnicas**

Crear `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-07-gatt-results.md` con esta plantilla, llenando los placeholders con lo observado:

```markdown
# Renpho Elis 1C — Resultados de reconocimiento GATT

**Fecha:** 2026-05-07
**Captura realizada con:** `renpho-explore` (fase 1.1)
**Comando:** `swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt.jsonl`

## Resumen de la sesión

- Total de eventos: `<N>`
- Disconnect prematuro: sí / no (en `<segundo>` aprox., razón: `<...>`)
- Pesada completada (peso visible en pantalla): sí / no

## Árbol GATT descubierto

### Service `<UUID-1>`

| Characteristic | Properties | Read result | Notifications |
|---------------|-----------|-------------|---------------|
| `<UUID>` | read,notify | `<hex>` | `<count>` |
| `<UUID>` | write | n/a | n/a |
| ...

### Service `<UUID-2>`

(Mismo formato si hay varios.)

## Payloads observados durante la pesada

Char `<UUID que más notifications emitió>`:

- Primer payload: `<hex>`
- Mid pesada: `<hex>`
- Final (con peso/composición): `<hex>`
- Diferencias visibles entre ellos: bytes `<N..M>` cambian de `<X>` a `<Y>` (probablemente peso); bytes `<P..Q>` aparecen al final (probablemente impedancia/composición).

(Si los payloads son largos, mejor referenciar las líneas del JSONL con `jq` que pegarlos todos aquí.)

## Conclusión: passive+read alcanza para la 1.2, o necesita writes

**Decisión:** `<passive+read>` / `<necesita writes>`

**Justificación:**
- Si **passive+read alcanza:** la char `<UUID>` emitió notifications con datos cambiantes durante la pesada y el payload final contiene peso (los bytes cambian con tu peso real). La 1.2 puede ser un cliente GATT que solo se conecta, se suscribe a esa char, y parsea.
- Si **necesita writes:** durante la pesada NO llegaron notifications (o las que llegaron tenían datos constantes / triviales tipo battery). Hay chars writable disponibles. La 1.2 va a tener que enviar comandos. Próximo paso: portar la rutina de inicialización de Renpho desde openScale (`com.health.openscale.core.bluetooth.lib.RenphoLib` o el plugin `BluetoothRenphoScale`).

## Implicaciones para la 1.2

(Una a tres frases sobre lo que cambia para el spec de la 1.2.)

## Artefactos

- `~/Projects/renpho-scale/gatt.jsonl` — sesión completa, NO commiteada (en `.gitignore`).
- Este archivo de notas — commiteado para input al spec de 1.2.
```

- [ ] **Step 6: Commit de las notas**

```bash
cd ~/Projects/renpho-scale
git add docs/superpowers/notes/2026-05-07-gatt-results.md
git commit -m "docs: árbol GATT del Elis 1C y decisión para la fase 1.2"
```

(Nota: `gatt.jsonl` no se commitea — está cubierto por `*.jsonl` en `.gitignore` desde la 1.0.)

---

## Definition of Done — Fase 1.1

Verificar los 5 criterios del spec:

1. [ ] `swift build` compila ambos targets sin warnings.
2. [ ] `renpho-explore --filter "R-A033" --duration 60 --verbose --out gatt.jsonl` ejecutado contra la balanza activa:
   - [ ] Conecta exitosamente.
   - [ ] Descubre al menos 1 service y al menos 1 characteristic.
   - [ ] Loguea al menos 1 evento de respuesta del peripheral (`read_ok`, `read_failed`, o `notification`).
3. [ ] `gatt.jsonl` es JSONL válido (`jq -c .` sin errores) y contiene la secuencia de eventos esperada.
4. [ ] Si `--filter` matchea pero el peripheral no responde a connect en `--connect-timeout` segundos, sale con exit 6 y mensaje claro.
5. [ ] Si la balanza no está activa al arrancar (no se ve el peripheral en 15s), sale con exit 5 con mensaje claro.

Y los artefactos:

- [ ] Repo `renpho-scale` con commits desde Task 1 a Task 5.
- [ ] `gatt.jsonl` existe localmente (no en git).
- [ ] `docs/superpowers/notes/2026-05-07-gatt-results.md` con árbol GATT y decisión binaria sobre 1.2 (passive+read vs writes).
