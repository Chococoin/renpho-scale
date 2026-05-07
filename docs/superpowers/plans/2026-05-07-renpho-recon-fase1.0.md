# Renpho Recon Fase 1.0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir `renpho-recon`, un CLI nativo en Swift para macOS que escanea BLE y vuelca todos los advertisement frames con resaltado de bytes que cambian, para descifrar el protocolo del Renpho Elis 1C.

**Architecture:** Un único target ejecutable de Swift Package Manager, sin dependencias externas. Cuatro archivos fuente: `main.swift` (parseo de args y orquestación), `Scanner.swift` (wrapper de `CBCentralManager` que expone un `AsyncStream<AdvertisementFrame>`), `Formatter.swift` (pretty-printer con diff de bytes), `Recorder.swift` (persistencia opcional a JSONL). El permiso de Bluetooth se resuelve embebiendo un `Info.plist` mínimo vía linker flag.

**Tech Stack:** Swift 5.9+, CoreBluetooth, Foundation. macOS 11 (Big Sur) o superior. Sin dependencias externas.

**Spec de referencia:** `docs/superpowers/specs/2026-05-07-renpho-recon-fase1.0-design.md`

**Sin TDD en esta fase:** el spec define explícitamente que la fase 1.0 no lleva tests automatizados; su valor es el artefacto JSONL contra la balanza real. La fase 1.1 sí los tendrá usando los fixtures producidos aquí.

---

## File Structure

| Archivo | Responsabilidad |
|---------|-----------------|
| `Package.swift` | Manifesto del paquete; define el target ejecutable y embebe el Info.plist vía linker flag. |
| `Resources/Info.plist` | Bundle metadata mínimo, principalmente `NSBluetoothAlwaysUsageDescription` para que macOS muestre el prompt de permiso. |
| `Sources/renpho-recon/main.swift` | Punto de entrada (`@main`); parsea argumentos, instancia Scanner/Formatter/Recorder, gestiona el ciclo de vida y exit codes. |
| `Sources/renpho-recon/Scanner.swift` | Modelo `AdvertisementFrame`, errores `ScannerError`, y clase `Scanner` que envuelve `CBCentralManager` y expone un `AsyncStream`. |
| `Sources/renpho-recon/Formatter.swift` | Pretty-printer con utilidades hex y resaltado ANSI de bytes que cambiaron entre frames consecutivos del mismo dispositivo. |
| `Sources/renpho-recon/Recorder.swift` | Persistencia opcional a JSONL: una línea JSON por frame, append a un `FileHandle`. |
| `.gitignore` | Excluir `.build/`, capturas (`*.jsonl`), `.DS_Store`, `.swiftpm/`. |
| `docs/superpowers/notes/2026-05-07-recon-results.md` | Notas técnicas con el byte layout descifrado del Elis 1C (producto de las tareas 7 y 8). |

---

## Task 1: Bootstrap del paquete Swift

**Files:**
- Create: `~/Projects/renpho-scale/Package.swift`
- Create: `~/Projects/renpho-scale/Resources/Info.plist`
- Create: `~/Projects/renpho-scale/Sources/renpho-recon/main.swift` (stub)
- Create: `~/Projects/renpho-scale/.gitignore`

- [ ] **Step 1: Crear `.gitignore`**

```gitignore
.build/
.swiftpm/
.DS_Store
*.jsonl
Package.resolved
```

- [ ] **Step 2: Crear `Package.swift`**

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
        )
    ]
)
```

- [ ] **Step 3: Crear `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.choco.renpho-recon</string>
    <key>CFBundleName</key>
    <string>renpho-recon</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>renpho-recon escanea dispositivos BLE cercanos para identificar y capturar datos de balanzas Renpho.</string>
</dict>
</plist>
```

- [ ] **Step 4: Crear stub `Sources/renpho-recon/main.swift`**

```swift
import Foundation

print("renpho-recon stub")
```

- [ ] **Step 5: Verificar que compila**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds, produce binario en `.build/debug/renpho-recon`.

- [ ] **Step 6: Verificar que el Info.plist quedó embebido**

Run: `otool -s __TEXT __info_plist .build/debug/renpho-recon | tail -20`
Expected: ver bytes del plist (no vacío). Si falla, el linker flag no aplicó; revisar `Package.swift`.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/renpho-scale
git add .gitignore Package.swift Resources/ Sources/
git commit -m "feat: bootstrap renpho-recon Swift package with embedded Info.plist"
```

---

## Task 2: Modelo `AdvertisementFrame` y `Scanner`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-recon/Scanner.swift`

- [ ] **Step 1: Crear `Scanner.swift` completo**

```swift
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

final class Scanner: NSObject, CBCentralManagerDelegate {
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
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds, sin warnings de nuestro código.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-recon/Scanner.swift
git commit -m "feat: Scanner wrapping CBCentralManager exposing AsyncStream<AdvertisementFrame>"
```

---

## Task 3: Formatter con diff de bytes

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-recon/Formatter.swift`

- [ ] **Step 1: Crear `Formatter.swift` completo**

```swift
import Foundation

/// Formatea AdvertisementFrames para impresión en consola.
/// Mantiene el último frame por dispositivo para resaltar bytes que cambiaron.
struct FrameFormatter {
    private var lastFrames: [UUID: AdvertisementFrame] = [:]

    static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Devuelve la representación hex de `data`, con los bytes que difieren de `previous`
    /// envueltos en escape ANSI rojo. Si `previous` es nil, no resalta nada.
    static func diffHex(_ data: Data, previous: Data?) -> String {
        guard let prev = previous else { return hex(data) }
        var out = ""
        for (i, byte) in data.enumerated() {
            let s = String(format: "%02x", byte)
            let prevByte: UInt8? = (i < prev.count) ? prev[prev.startIndex.advanced(by: i)] : nil
            if prevByte == byte {
                out += s
            } else {
                out += "\u{001B}[31m\(s)\u{001B}[0m"
            }
        }
        return out
    }

    /// Renderiza un frame. Si `verbose` es false y el contenido no cambió respecto al
    /// frame previo del mismo dispositivo, devuelve nil (no se imprime).
    mutating func format(_ frame: AdvertisementFrame, verbose: Bool) -> String? {
        let prev = lastFrames[frame.identifier]
        let changed = (prev?.manufacturerData != frame.manufacturerData)
            || (prev?.serviceData != frame.serviceData)
        defer { lastFrames[frame.identifier] = frame }
        if !verbose && !changed && prev != nil { return nil }

        let ts = ISO8601DateFormatter.fractional.string(from: frame.timestamp)
        let name = frame.name ?? "<unnamed>"
        let shortId = String(frame.identifier.uuidString.prefix(8))
        var lines = ["[\(ts)] \(name) (\(shortId)) rssi=\(frame.rssi)"]

        if let mfg = frame.manufacturerData {
            lines.append("  mfg: \(FrameFormatter.diffHex(mfg, previous: prev?.manufacturerData))")
        }
        if !frame.serviceUUIDs.isEmpty {
            let uuids = frame.serviceUUIDs.map { $0.uuidString }.joined(separator: ", ")
            lines.append("  services: \(uuids)")
        }
        for (uuid, data) in frame.serviceData {
            let prevData = prev?.serviceData[uuid]
            lines.append("  serviceData[\(uuid.uuidString)]: \(FrameFormatter.diffHex(data, previous: prevData))")
        }
        return lines.joined(separator: "\n")
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
Expected: build succeeds, sin warnings.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-recon/Formatter.swift
git commit -m "feat: FrameFormatter with ANSI byte diffing between consecutive frames"
```

---

## Task 4: Recorder JSONL

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-recon/Recorder.swift`

- [ ] **Step 1: Crear `Recorder.swift` completo**

```swift
import Foundation

enum RecorderError: Error {
    case cannotOpen(path: String)
}

/// Escribe AdvertisementFrames como JSONL. Si se construye con path nil, no hace nada.
final class Recorder {
    private let handle: FileHandle?

    init(path: String?) throws {
        guard let path = path else {
            self.handle = nil
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw RecorderError.cannotOpen(path: path)
        }
        try h.seekToEnd()
        self.handle = h
    }

    func record(_ frame: AdvertisementFrame) {
        guard let handle = handle else { return }
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter.fractional.string(from: frame.timestamp),
            "id": frame.identifier.uuidString,
            "rssi": frame.rssi
        ]
        if let name = frame.name {
            dict["name"] = name
        }
        if let mfg = frame.manufacturerData {
            dict["mfg"] = FrameFormatter.hex(mfg)
        }
        if !frame.serviceUUIDs.isEmpty {
            dict["services"] = frame.serviceUUIDs.map { $0.uuidString.lowercased() }
        }
        if !frame.serviceData.isEmpty {
            let pairs = frame.serviceData.map { (key, value) in
                (key.uuidString.lowercased(), FrameFormatter.hex(value))
            }
            dict["serviceData"] = Dictionary(uniqueKeysWithValues: pairs)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func close() {
        try? handle?.close()
    }
}
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds, sin warnings.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-recon/Recorder.swift
git commit -m "feat: Recorder writing AdvertisementFrames as JSONL"
```

---

## Task 5: CLI orchestration en `main.swift`

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-recon/main.swift` (reemplazar stub)

- [ ] **Step 1: Reemplazar `main.swift` con la implementación completa**

```swift
import Foundation

struct Args {
    var duration: TimeInterval = 30
    var filter: String? = nil
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
        case "--duration":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --duration requires a positive number")
                exit(1)
            }
            args.duration = d
        case "--filter":
            i += 1
            guard i < argv.count else {
                writeError("error: --filter requires a value")
                exit(1)
            }
            args.filter = argv[i]
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
            print("usage: renpho-recon [--duration <seconds>] [--filter <substring>] [--verbose] [--out <path>]")
            exit(0)
        default:
            writeError("error: unknown arg \(a)")
            exit(1)
        }
        i += 1
    }
    return args
}

@main
struct RenphoRecon {
    static func main() async {
        let args = parseArgs()

        let recorder: Recorder
        do {
            recorder = try Recorder(path: args.out)
        } catch {
            writeError("error: cannot open output file: \(error)")
            exit(4)
        }
        defer { recorder.close() }

        let scanner = Scanner()
        let stream: AsyncStream<AdvertisementFrame>
        do {
            stream = try await scanner.start()
        } catch ScannerError.bluetoothUnauthorized {
            writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
            exit(2)
        } catch ScannerError.bluetoothPoweredOff {
            writeError("error: Bluetooth is off. Please enable it.")
            exit(3)
        } catch {
            writeError("error: \(error)")
            exit(1)
        }

        var formatter = FrameFormatter()
        var counts: [UUID: (name: String?, count: Int)] = [:]

        let durationNanos = UInt64(args.duration * 1_000_000_000)
        let timerTask = Task {
            try? await Task.sleep(nanoseconds: durationNanos)
            scanner.stop()
        }

        for await frame in stream {
            if let filter = args.filter {
                let name = frame.name ?? ""
                if !name.lowercased().contains(filter.lowercased()) { continue }
            }
            let entry = counts[frame.identifier] ?? (frame.name, 0)
            counts[frame.identifier] = (frame.name ?? entry.name, entry.count + 1)

            if let line = formatter.format(frame, verbose: args.verbose) {
                print(line)
            }
            recorder.record(frame)
        }
        timerTask.cancel()

        if counts.isEmpty {
            print("\nNo devices detected. Is the scale active?")
        } else {
            print("\n--- Summary ---")
            let sorted = counts.sorted { $0.value.count > $1.value.count }
            for (id, info) in sorted {
                let shortId = String(id.uuidString.prefix(8))
                print("\(info.name ?? "<unnamed>") (\(shortId)): \(info.count) frames")
            }
        }
        exit(0)
    }
}
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds, sin warnings.

- [ ] **Step 3: Verificar el `--help`**

Run: `cd ~/Projects/renpho-scale && swift run renpho-recon --help`
Expected: imprime el usage y termina con exit 0.

- [ ] **Step 4: Verificar manejo de args inválidos**

Run: `cd ~/Projects/renpho-scale && swift run renpho-recon --duration -5; echo "exit=$?"`
Expected: stderr "error: --duration requires a positive number", exit 1.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-recon/main.swift
git commit -m "feat: CLI orchestration with arg parsing, exit codes, and summary"
```

---

## Task 6: Smoke test — primer permiso de Bluetooth y scanner funcional

Este es un paso manual que NO produce código. Su propósito es verificar que el binario, al ejecutarse por primera vez, dispara el prompt de Bluetooth de macOS y que después puede listar dispositivos BLE arbitrarios cercanos.

- [ ] **Step 1: Ejecutar por primera vez (sin balanza activa)**

Run: `cd ~/Projects/renpho-scale && swift run renpho-recon --duration 15`
Expected: macOS muestra un diálogo modal pidiendo permiso de Bluetooth para `renpho-recon`.

- [ ] **Step 2: Aprobar el permiso**

Aceptar en el diálogo. Si por alguna razón no aparece, ir a System Settings → Privacy & Security → Bluetooth y agregar/aprobar `renpho-recon`. Re-ejecutar el comando del Step 1 si fue necesario.

- [ ] **Step 3: Verificar que detecta dispositivos**

El comando debería listar al menos un dispositivo BLE (p. ej. el iPhone, AirPods, o cualquier otro device cercano), seguido del bloque `--- Summary ---`.

Si no aparece nada y exit code es 2 → permiso aún no aplicado; volver al Step 2.
Si exit code es 3 → Bluetooth está apagado; encenderlo y reintentar.

- [ ] **Step 4: (Solo si fue necesario un fix) commit**

Si surgió algún problema y se corrigió código, hacer commit puntual aquí. Si todo funcionó al primer intento, no hay commit en esta tarea.

---

## Task 7: Captura de identificación — encontrar el Elis 1C

**Files:**
- Create: `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-07-recon-results.md`

- [ ] **Step 1: Asegurar que la balanza esté apagada antes de empezar**

Ninguna acción de código.

- [ ] **Step 2: Lanzar escaneo y activar la balanza durante el escaneo**

Run: `cd ~/Projects/renpho-scale && swift run renpho-recon --duration 30 --verbose`

Mientras corre: subirse a la balanza para activarla, bajarse, repetir un par de veces. El objetivo es ver qué dispositivo BLE aparece sólo cuando la balanza está activa.

- [ ] **Step 3: Identificar el Elis 1C en el resumen**

Buscar en el `--- Summary ---` un dispositivo cuyo nombre contenga "Renpho", "Elis", o que sea desconocido y haya emitido frames sólo durante la activación. Anotar el nombre exacto y los primeros 8 caracteres del UUID.

- [ ] **Step 4: Crear el archivo de notas con la identificación**

Crear `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-07-recon-results.md` con el contenido inicial:

```markdown
# Renpho Elis 1C — Resultados de reconocimiento BLE

**Fecha:** 2026-05-07
**Captura realizada con:** `renpho-recon` (fase 1.0)

## Identificación del dispositivo

- **Nombre BLE advertisado:** `<NOMBRE_OBSERVADO>`
- **Identifier (CoreBluetooth UUID, primeros 8 chars):** `<UUID_PREFIX>`
- **Service UUIDs advertisados:** `<LISTA>`
- **Manufacturer data presente en advertisement:** sí / no
- **RSSI típico a ~1m:** `<RSSI>`

## Pasada de captura activa

Pendiente — Tarea 8.

## Byte layout descifrado

Pendiente — Tarea 8.

## Conclusión: ¿advertisement o GATT?

Pendiente — Tarea 8.
```

Reemplazar los placeholders `<...>` con los valores observados.

- [ ] **Step 5: Commit de las notas**

```bash
cd ~/Projects/renpho-scale
git add docs/superpowers/notes/
git commit -m "docs: identificación BLE del Elis 1C en captura inicial"
```

---

## Task 8: Captura activa — pesada completa y descifrado del byte layout

- [ ] **Step 1: Lanzar la captura filtrada con persistencia**

Usar el nombre identificado en la Tarea 7. Ejemplo si fue "Renpho":

Run:
```bash
cd ~/Projects/renpho-scale
swift run renpho-recon --filter "renpho" --duration 90 --verbose --out captura.jsonl
```

Mientras corre: subirse a la balanza descalzo, esperar a que muestre el peso final y la composición (típicamente la app oficial recibe los datos en este momento), bajarse. Si es posible, repetir 2 pesadas en la misma sesión.

- [ ] **Step 2: Verificar que el JSONL es válido**

Run: `jq -c . ~/Projects/renpho-scale/captura.jsonl | wc -l`
Expected: número > 10 (frames durante la pesada).

Run: `jq -c '. | {ts, name, mfg}' ~/Projects/renpho-scale/captura.jsonl | head -5`
Expected: ver entradas válidas con timestamp, nombre y mfg en hex.

- [ ] **Step 3: Inspeccionar la consola del Step 1 para identificar bytes que cambiaron**

Mirar el output de la consola de la captura. Anotar:
- ¿Qué bytes (posiciones 0-N en hex) cambiaron al subir/bajar? → candidatos a ser **peso**.
- ¿Aparecieron bytes nuevos hacia el final de la pesada (cuando la balanza tomó la medición de impedancia)? → candidatos a ser **impedancia** y **flag de medición estable**.
- ¿Hay bytes que nunca cambian? → header / device ID / constantes.

Si la consola scrolleó demasiado, regenerar el análisis offline contra `captura.jsonl`. Ejemplo de comando útil:

```bash
jq -r 'select(.name | test("renpho"; "i")) | .mfg' ~/Projects/renpho-scale/captura.jsonl \
    | awk '!seen[$0]++' \
    | head -50
```

Esto muestra los valores únicos de `mfg` en el orden en que aparecieron.

- [ ] **Step 4: Comparar con el código de openScale para confirmar el layout**

openScale tiene parsers de Renpho en su repo (`com.health.openscale.core.bluetooth.lib.RenphoLib` y similares). Buscar en GitHub el archivo correspondiente al modelo Elis 1C y confirmar que el byte layout observado coincide con uno de los formatos conocidos. Si no se encuentra match, asumir que el Elis 1C usa un formato no documentado en openScale y registrar las observaciones empíricas.

- [ ] **Step 5: Si no se vio peso/impedancia en advertisement, evaluar GATT**

Si los frames del Elis 1C tienen `mfg` constante o muy poco cambio, es probable que la balanza emita los datos por GATT y haya que conectarse + leer una característica. En ese caso:
- Anotar `services` advertisados (Service UUIDs).
- Documentar en las notas que la fase 1.1 deberá conectarse y leer características.
- No hacer la conexión en esta fase (queda para 1.1).

- [ ] **Step 6: Completar las notas con los hallazgos**

Editar `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-07-recon-results.md` reemplazando los "Pendiente" con:

- **Pasada de captura activa**: número de frames totales, cuántas pesadas, comportamiento observado (los bytes X-Y cambian con el peso, los bytes Z-W aparecen al final, etc.).
- **Byte layout descifrado** (si fue por advertisement): tabla de offset → significado → endianness → unidad. Por ejemplo:

  | Offset | Bytes | Significado | Notas |
  |--------|-------|-------------|-------|
  | 0 | 1 | Header constante (`0xff`) | |
  | 1-2 | 2 | Peso × 100 | little-endian, kg |
  | 3 | 1 | Flag medición estable | bit 0 = estable |
  | 4-7 | 4 | Impedancia | ohms, sólo cuando estable |
  | 8 | 1 | Checksum XOR | |

- **Conclusión: ¿advertisement o GATT?**: una de las dos opciones, con justificación de una frase.

- [ ] **Step 7: Commit de las notas finales**

```bash
cd ~/Projects/renpho-scale
git add docs/superpowers/notes/
git commit -m "docs: byte layout del Elis 1C descifrado en sesión de captura activa"
```

Nota: `captura.jsonl` está en `.gitignore` y NO se commitea — es un fixture local para la fase 1.1, no parte del repo.

---

## Definition of Done — Fase 1.0

Verificar que se cumplen los 5 criterios del spec:

1. [ ] `swift build` compila sin warnings.
2. [ ] Ejecución sin balanza listó al menos un dispositivo BLE cercano.
3. [ ] Ejecución con la balanza activa registró ≥ 10 frames del Elis 1C en `captura.jsonl`.
4. [ ] `jq -c . captura.jsonl` no produce errores.
5. [ ] El diff de bytes hizo identificable a ojo desnudo qué bytes cambian con el peso (o se documentó que el Elis 1C requiere GATT).

Y los artefactos:

- [ ] Repo `renpho-scale` con commits desde el bootstrap hasta las notas.
- [ ] `captura.jsonl` existe localmente (no en git).
- [ ] `docs/superpowers/notes/2026-05-07-recon-results.md` contiene el byte layout descifrado o la decisión de ir por GATT.
