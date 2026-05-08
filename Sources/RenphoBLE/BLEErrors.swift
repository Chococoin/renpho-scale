import Foundation

/// Errores compartidos sobre el estado del adaptador Bluetooth y el scan.
/// Errores específicos del flujo de cada cliente (connectFailed, etc.) viven en
/// el módulo del cliente, no acá.
public enum BLEPowerError: Error {
    case unauthorized
    case poweredOff
    case unsupported
}

public enum BLEScanError: Error {
    case timeoutNoMatch
}
