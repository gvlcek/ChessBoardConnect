# ChessBoardConnect

Paquete Swift independiente para conectar tableros electrónicos. Swift 6, iOS 17+ y macOS 14+. Sin dependencias externas; Foundation, Combine y Core Bluetooth son frameworks de Apple. macOS permite ejecutar los tests sin un iPhone; la radio del Go sigue pendiente de validación física.

## Uso desde otra app

En Xcode: Add Package Dependencies → Add Local → elegir esta carpeta y enlazar el producto `ChessBoardConnect` al target. En un paquete Swift consumidor:

```swift
// Package.swift (rutas relativas al paquete consumidor)
.package(path: "../ChessBoardConnect")
// En dependencies del target:
.product(name: "ChessBoardConnect", package: "ChessBoardConnect")
```

La aplicación host debe declarar `NSBluetoothAlwaysUsageDescription` en su Info.plist. En macOS con App Sandbox también debe habilitar el permiso Bluetooth. El paquete no incluye pantallas ni solicita permisos hasta iniciar la búsqueda.

```swift
import ChessBoardConnect
import Combine

@MainActor
final class MyBoardModel {
    let connect = BoardConnect()
    private var subscriptions = Set<AnyCancellable>()

    init() {
        connect.$position.sink { position in
            // nil significa que no hay una lectura vigente.
            print(position?.fen ?? "Sin posición")
        }.store(in: &subscriptions)

        connect.$state.sink { print($0) }.store(in: &subscriptions)
    }

    func search() { connect.scan() }
    func select(_ board: BoardDevice) throws { try connect.connect(board.id) }
    func guideE4() throws {
        guard connect.capabilities.contains(.controlLights) else { return }
        try connect.send(.setLights([BoardPosition.index("e2")!, BoardPosition.index("e4")!]))
    }
}
```

Con SwiftUI se puede observar `BoardConnect` usando `@StateObject` y sus propiedades publicadas. Cada suscriptor recibe sus propios cambios: no hay un callback de posición único que una pantalla pueda reemplazar accidentalmente.

## Contrato

- `devices`: dispositivos compatibles descubiertos; identidad, nombre, señal y capacidades.
- `state`: estados tipados para búsqueda, conexión, recepción, desconexión y fallo. `status` ofrece un texto de diagnóstico.
- `position`: colocación de las 64 piezas, normalizada como primer campo FEN; no inventa turno, derechos de enroque ni legalidad.
- `lastMove`: última jugada reportada por un driver que emita jugadas; el driver Chessnut actual entrega posiciones y no infiere movimientos.
- `capabilities`: permite comprobar si el tablero soporta lectura, luces, envío de jugadas o carga de posiciones.
- `send`: comandos comunes; falla con `unsupportedCapability` si el driver conectado no ofrece esa operación. Retornar sin error confirma que el comando fue encolado, no que una persona haya movido las piezas.
- `showLights` / `refresh`: atajos de los comandos correspondientes.
- `disconnect`, `reconnect`, `stopScan`: ciclo de conexión explícito. Tras desconectar, se descartan posiciones y comandos pendientes. Reconectar exige recibir una lectura nueva.
- `logs`: registro de diagnóstico acotado a 200 eventos, sin almacenamiento persistente.

Las coordenadas públicas son índices a8=0...h8=7, a1=56...h1=63. `BoardPosition.index("e4")` evita depender de esa numeración. Luces con `[]` significa apagar todas. Los datos se publican en MainActor. Los errores se informan con `ConnectError` o con `state.failed`; una recepción inválida invalida la posición vigente.

## Fabricantes

| Driver | Estado | Capacidades actuales |
| --- | --- | --- |
| Chessnut clásico | Extraído de la prueba del Go; pendiente de hardware | Leer posición, controlar luces |
| ChessUp / ChessUp 2 | Pendiente, no registrado | Ninguna anunciada todavía |

El registro clásico reconoce nombres Chessnut y excluye explícitamente Move y Evo, que no deben recibir este protocolo por coincidencia de marca. Go es el objetivo de las pruebas físicas; no se asegura compatibilidad de todos los firmware clásicos.

## Agregar otro tablero

Todo se cambia dentro de este paquete:

1. Implementar `BoardDriver` internamente: capacidades, perfil Bluetooth, comandos iniciales, codificación de comandos y decodificación de notificaciones.
2. Agregar una fábrica y un filtro de nombre a `DriverRegistry.standard`. Cada conexión crea un driver nuevo para no compartir buffers ni estado de protocolo.
3. Emitir eventos normalizados `position` / `move`; un driver puede responder al tablero mediante eventos `write`. Extender su handshake o transporte en el módulo si el hardware requiere otra negociación.
4. Agregar fixtures del protocolo y validar con hardware real. Las apps siguen consumiendo la misma interfaz y consultando capacidades.

`BoardConnect` es la fachada pública; `BluetoothSession` resuelve el transporte; los drivers conocen los mensajes del fabricante. No hay UUIDs, canales o paquetes Bluetooth en la interfaz pública. PGN, catálogo de partidas, debounce de estudio y confirmación de objetivos pertenecen a la app consumidora.

El paquete puede copiarse a un repositorio independiente manteniendo su `Package.swift`. Chess Dex usa una dependencia local para que el desarrollo y las pruebas no requieran publicar nada.

## Tests

```sh
swift test
```

Se verifican bytes conocidos del protocolo, orientación, paquetes parciales, entradas inválidas, contrato de comandos sin conexión, múltiples suscriptores y registro de un driver adicional de prueba. Los tests no encienden Bluetooth. No se ha incorporado código de la extensión Chessconnect.

Fuentes del protocolo clásico:
- https://github.com/chessnutech/Chessnut_eBoards
- https://github.com/chessnutech/EasyLinkSDK/blob/main/sdk/EasyLink.cpp

El envío de luces usa 10 bytes, conforme al código del SDK del fabricante; su README es ambiguo al mencionar 34 bytes y mostrar un comando de 10. Confirmar con el Go antes de declarar compatibilidad validada.
