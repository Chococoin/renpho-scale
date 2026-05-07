# Renpho Elis 1C — Resultados de reconocimiento GATT

**Fecha:** 2026-05-07
**Captura realizada con:** `renpho-explore` (fase 1.1)
**Comando:** `swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt.jsonl`
**Duración real de sesión:** ~31 s (la balanza se desconectó sola tras la medición de impedancia)

## Resumen de la sesión

- **61 eventos** registrados en `gatt.jsonl` (lifecycle + discovery + reads + notifications + disconnect).
- **4 services**, **12 characteristics**, **8 reads ok**, **3 notify subscriptions**, **28 notifications** durante la pesada.
- Disconnect prematuro a los ~31 s con error "The specified device has disconnected from us." → comportamiento normal del Elis 1C: post-medición se apaga sola.
- Pesada completada con peso e impedancia visibles en pantalla.

## Árbol GATT descubierto

### Service `1a10` — propietario Renpho

Coincide con el company ID `0x1A10` que vimos en el manufacturer data del advertisement BLE en la fase 1.0 (bytes `10 1a` little-endian).

| Characteristic | Properties | Read result | Notifications |
|---------------|-----------|-------------|---------------|
| `2a11` | write | n/a (no leído) | n/a |
| `2a10` | notify | n/a | **28** ← stream de medición |

### Service `180a` — Device Information (estándar Bluetooth SIG)

Todas las characteristics readable; los valores hex decodifican a ASCII (excepto `2a23` que es el MAC):

| Characteristic | Property | Hex | ASCII / valor decodificado |
|---------------|----------|-----|----------------------------|
| `2a29` | read | `4c654675205363616c65` | `"LeFu Scale"` (Manufacturer Name) |
| `2a24` | read | `3338343030` | `"38400"` (Model Number) |
| `2a25` | read | `<serial-bytes>` | `"<serial>"` (Serial Number — string ASCII de 8 dígitos por unidad) |
| `2a27` | read | `76312e33` | `"v1.3"` (Hardware Revision) |
| `2a28` | read | `56322e39` | `"V2.9"` (Firmware Revision) |
| `2a26` | read | `6f6d` | `"om"` (Software Revision String — extraño, probablemente trunc / ID interno) |
| `2a23` | read | `<mac-bytes>` | MAC `aa:bb:cc:dd:ee:ff` (System ID, mismo que en advertisement; per-device) |

LeFu es la empresa madre de Renpho. Confirma identificación del fabricante.

### Service `180f` — Battery (estándar Bluetooth SIG)

| Characteristic | Property | Read result |
|---------------|----------|-------------|
| `2a19` | read,notify | `0x64` = **100%** batería |

Suscripción a notify exitosa pero no llegaron updates de batería en los 31 s (la balanza está cargada al tope, el nivel no cambió).

### Service `fe59` — Nordic Semiconductor DFU

Service de firmware update del SoC Nordic. Sin uso operacional.

| Characteristic | Property |
|---------------|----------|
| `8ec90001-f315-4f60-9fb8-838830daea50` | write,notify |
| `8ec90002-f315-4f60-9fb8-838830daea50` | writeWithoutResponse |

Suscripción a notify exitosa, sin notifications.

## Payloads observados durante la pesada

Stream del char `2a10` durante la pesada — 28 notifications, mostradas con los **bytes de peso e impedancia anonimizados** como `WW WW` y `II II` (los específicos identificarían al sujeto). Conteos y estructura sí son reales:

| Count | Payload (anonimizado) | Tipo |
|-------|-----------------------|------|
| 4 | `55aa11 00 05 01 01 01 09 21` | Idle (pre-pesada) |
| 1 | `55aa14 00 07 00 00 WW WW 00 00 CK` | Peso primer reading al subirse |
| 1 | `55aa14 00 07 00 00 WW WW 00 00 CK` | Peso settling |
| 13 | `55aa14 00 07 00 00 WW WW 00 00 CK` | Peso estable (dominante en el log) |
| 4 | `55aa14 00 07 00 00 WW WW 00 00 CK` | Peso oscilando 1 LSB respecto al estable |
| 3 | `55aa14 00 07 01 00 WW WW II II CK` | **Peso final + impedancia (medición completa, flag=01)** |
| 3 | `55aa11 00 05 00 01 01 09 20` | Idle (post-pesada, status byte 0 cambia 01→00) |

## Estructura de frame del char 2a10 (decodificación tentativa)

Los frames tienen una estructura consistente: `55aa` sync + tipo + len + payload + checksum.

### Frame "idle" (tipo 0x11)

```
55 aa  11 00  05  XX 01 01 09  CK
```

- `55 aa` — sync header
- `11 00` — message type 0x0011 (idle/status)
- `05` — length del payload (5 bytes)
- `XX 01 01 09` — status bytes; `XX` cambia: `01` pre-pesada, `00` post-pesada
- `CK` — checksum (último byte): `21` cuando `XX=01`, `20` cuando `XX=00` → diff de 1, consistente con XOR/suma

### Frame "measurement" (tipo 0x14)

```
55 aa  14 00  07  FL FL  WW WW  II II  CK
```

- `55 aa` — sync header
- `14 00` — message type 0x0014 (measurement)
- `07` — length del payload (7 bytes)
- `FL FL` — flags (2 bytes); byte 0 = bit de "impedance ready" (`00` durante pesado, `01` cuando llega impedancia)
- `WW WW` — peso (big-endian, **factor 0.01 kg / 10 g por LSB**, confirmado contra peso real conocido)
  - Ejemplo conceptual: si los bytes son `0x1D4C` → 7500 decimal × 0.01 = 75.00 kg
  - Resolución interna 10 g; el display redondea a 50 g (consistente con marketing Renpho)
  - Jumps observados durante el settling: 100-200 g, normales por oscilación postural
- `II II` — impedancia (big-endian, ohms); `00 00` mientras flag=00, valor real cuando flag=01
  - Rango normal adulto: 300-700 ohms (ej. `0x01F4` = 500 ohms)
- `CK` — checksum (último byte)

**Observaciones para el spec de la 1.2:**

- Confirmar el algoritmo de checksum (XOR de payload, suma mod 256, etc.) — pendiente para 1.2.
- Factor de peso **confirmado: 0.01 kg/LSB** contra peso real conocido durante la sesión de captura.
- Verificar comportamiento si la pesada NO incluye impedancia (ej. si el usuario está descalzo pero la corriente no fluye correcto): probablemente el flag se queda en 0 y la balanza se apaga sin emitir frame con impedancia.
- El frame "idle post-pesada" con `XX=00` parece marcar "I'm done, going to sleep" — útil como señal de fin de sesión productiva en la 1.2.

## Conclusión: passive+read alcanza para la 1.2 ✅

La balanza emite peso e impedancia por notification en char `2a10` sin necesidad de comandos previos. El cliente productivo de la fase 1.2 puede:

1. Conectarse al peripheral (filtrar por nombre `R-A033`).
2. Suscribirse a `1a10/2a10`.
3. Parsear las notifications según la estructura documentada arriba.
4. Calcular composición corporal (% grasa, masa muscular, etc.) con peso + impedancia + bio data del usuario (altura, edad, sexo).
5. Detectar fin de sesión por (a) flag impedance=01 + N segundos, (b) frame idle con `XX=00`, o (c) disconnect.

**No hace falta escribir a `2a11` ni a ningún otro char.** Esto simplifica significativamente la fase 1.2 — descartamos la rama "necesita writes" del spec original.

## Implicaciones para el spec de la fase 1.2

- Foco en **parser de frames + cálculo de composición**, no en handshake/comandos.
- Suscribir a `1a10/2a10`. El resto de chars son ignorables para el flujo principal (DIS y battery son datos contextuales que podemos leer una vez al conectar y guardar como metadata).
- El timing del fin de medición es claro: aparece un frame con `flags[0]=01` y impedancia no-cero. La 1.2 puede emitir el evento "medición completa" en ese instante y, si querés, esperar al siguiente disconnect para terminar.
- Las fórmulas de composición corporal (% grasa, masa muscular, etc.) las portamos de openScale (`com.health.openscale.core.bluetooth.lib.RenphoLib` o el plugin `BluetoothRenphoScale`). Necesitamos altura, edad y sexo del usuario en config.

## Artefactos

- `~/Projects/renpho-scale/gatt.jsonl` — sesión completa, 61 eventos, NO commiteada (en `.gitignore`).
- Este archivo de notas — commiteado para input al spec de 1.2.
