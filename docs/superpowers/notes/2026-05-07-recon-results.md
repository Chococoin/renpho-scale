# Renpho Elis 1C — Resultados de reconocimiento BLE

**Fecha:** 2026-05-07
**Captura realizada con:** `renpho-recon` (fase 1.0)

## Identificación del dispositivo

| Campo | Valor |
|-------|-------|
| Nombre BLE | `R-A033` |
| CoreBluetooth identifier (host-stable UUID) | `<peripheral-uuid>` (estable per-host) |
| MAC address (extraída del manufacturer data) | `aa:bb:cc:dd:ee:ff` (ejemplo, random-static type) |
| RSSI típico a ~50 cm | -49 a -55 dBm |
| Service UUIDs en advertisement | **ninguno** (la balanza no advertisa services) |
| Manufacturer data presente | sí, **constante** (`101a00040003aabbccddeeff0101`, MAC bytes anonimizados) |

`R-A033` es el nombre genérico que Renpho asigna a varios modelos básicos; el modelo físico es Elis 1C. CoreBluetooth no expone el MAC real del dispositivo (lo enmascara con un identifier estable per-host por privacidad), pero el MAC sí aparece dentro del payload del manufacturer data — útil para identificación inequívoca de la balanza si en el futuro hay múltiples Renphos cerca.

## Análisis del manufacturer data

`101a00040003<MAC>0101` — 14 bytes, **idéntico en los 172 frames capturados** durante una sesión completa de pesada (90 s). Lectura tentativa:

| Offset | Bytes | Valor (hex) | Lectura |
|--------|-------|-------------|---------|
| 0-1    | 2     | `10 1a`     | Company ID en little-endian → **0x1A10**. No es Apple/Nordic/Espressif/Realtek; presumiblemente Renpho o el SoC del módulo BLE. |
| 2-5    | 4     | `00 04 00 03` | Posible versión/flags. Constante. |
| 6-11   | 6     | `XX XX XX XX XX XX` | MAC address (top 2 bits del byte 0 = `11` → "random static" type, conforme spec BLE). |
| 12-13  | 2     | `01 01`     | Posible flags/estado. Constante. |

**No hay bytes que codifiquen peso ni impedancia.** El advertisement es un puro "I'm here, my MAC is X, I'm a Renpho R-A033".

## Pasada de captura activa

- Filtro: `--filter "R-A033"`
- Duración: 90 s
- Modo: `--verbose`
- Output: `captura.jsonl` (en `.gitignore`, no commiteado)
- **Total frames: 172**
- **Valores únicos de `mfg`: 1**

Durante los 90 s el usuario:
1. Activó la balanza subiéndose y bajándose una vez.
2. Se subió descalzo y se mantuvo quieto hasta que la balanza mostró peso final + composición corporal en la pantalla (típico flujo de medición Renpho).
3. Bajó.

El manufacturer data **no varió en ningún momento** — ni durante la activación, ni durante la medición de peso, ni durante la fase de impedancia, ni después de la medición.

El RSSI sí varía (-49 a -72 dBm) pero eso es propagación física, no datos.

## Conclusión: advertisement o GATT

**El Elis 1C usa GATT.** Razones:

1. El advertisement es 100% estático durante toda la pesada — peso, impedancia y composición corporal no salen por aquí.
2. La balanza no advertisa Service UUIDs en el advertisement, lo cual es coherente con un dispositivo que espera conexiones GATT activas (la app oficial sabe a qué service conectarse de antemano).
3. La balanza emite advertisements continuamente mientras está activa (~2 frames/segundo según la captura), comportamiento típico de un peripheral esperando ser conectado.

## Implicaciones para la fase 1.1

La fase 1.1 ya no es "parsear advertisements" sino "cliente GATT":

1. Conectarse al peripheral (`CBPeripheral`) usando el identifier UUID o filtrando por nombre `R-A033` durante un escaneo previo.
2. Hacer service discovery (`peripheral.discoverServices(nil)`).
3. Hacer characteristic discovery sobre los services encontrados.
4. Suscribirse a notifications en las characteristics relevantes (`peripheral.setNotifyValue(true, for:)`).
5. Capturar las notifications durante una pesada y, ahí sí, decodificar peso + impedancia.

**Pre-trabajo opcional antes de codear:** usar una app como **LightBlue** (App Store, gratuita) o **Bluetility** para conectarse manualmente al `R-A033` y ver qué services y characteristics expone. Eso nos da el "byte layout" rápidamente sin tener que iterar en código.

Renpho usa típicamente service `0xFFE0` o similar con una characteristic notify para datos. Hay parsers en `openScale` (`com.health.openscale.core.bluetooth.lib.RenphoLib` o el `BluetoothRenphoScale` plugin) que se pueden adaptar como referencia para el byte layout de las notifications.

## Artefactos

- `~/Projects/renpho-scale/captura.jsonl` — 172 frames JSONL (NO commiteado, en `.gitignore`).
- Este archivo de notas — commiteado para servir de input al spec de la fase 1.1.
