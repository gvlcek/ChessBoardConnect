# ConnectTestApp

App iPhone de diagnóstico para probar **ChessBoardConnect sin Chess Dex**. Usa exclusivamente `import ChessBoardConnect` y su API pública; no incorpora drivers, UUIDs ni comandos de fabricante propios.

## Ejecutar

1. Abrir `ConnectTestApp.xcodeproj` en esta carpeta.
2. Seleccionar el target **ConnectTestApp** → Signing & Capabilities → elegir tu equipo de desarrollo. El proyecto no lleva un equipo configurado; el Bundle Identifier se puede cambiar por uno disponible en tu cuenta.
3. Elegir un iPhone físico con iOS 17+ y ejecutar el esquema **ConnectTestApp**.
4. Encender el Go y desconectarlo de otras apps. Tocar **Buscar**, aceptar el permiso Bluetooth y elegirlo en la lista.

El proyecto referencia el paquete en `../..`, por lo que funciona tanto desde un clon independiente de ChessBoardConnect como desde la copia local dentro de Chess Dex. No depende del proyecto ChessDex.xcodeproj. Para probar hardware no usar el simulador como evidencia de conexión.

## Pantallas y controles

- **Conexión:** estado del módulo, búsqueda, detención, selección, desconexión y reconexión.
- **Capacidades:** lectura, luces, envío de jugadas y carga de posiciones según el driver conectado. El Go actual ofrece lectura y luces. ChessUp todavía no está implementado.
- **Posición:** 64 casillas recibidas, coordenadas y primer campo FEN; contador y hora de la última lectura. Desconectar o solicitar una lectura nueva invalida la posición anterior.
- **Luces:** escribir casillas como `e2 e4` o `a1, h8`, encenderlas y apagar todas. Se rechazan entradas inválidas.
- **Jugadas / FEN:** controles visibles solo cuando un driver anuncia esas capacidades; no se simulan para el Go.
- **Diagnóstico:** últimos eventos visibles, campo opcional de firmware y exportación del registro (máximo 200 eventos del módulo). Incluye fecha, versión de la test app, tipo de dispositivo y versión iOS, nombre del tablero, capacidades, posición y bytes TX/RX.

Un comando aceptado está **encolado**. La indicación de la app no demuestra que el firmware lo haya ejecutado ni que se hayan movido las piezas; observar el tablero y las lecturas.

## Checklist de hardware

Registrar modelo de tablero, firmware, iPhone e iOS al probar:

| Prueba | Resultado esperado |
| --- | --- |
| Buscar con el Go apagado | No aparece un dispositivo nuevo; búsqueda termina o se puede detener |
| Rechazar permiso Bluetooth | Mensaje de permiso y ausencia de conexión |
| Buscar y seleccionar Go | Se conecta y recibe al menos una posición |
| Posición inicial | Las 64 casillas coinciden con las piezas físicas |
| Mover y devolver un peón | FEN y contador cambian con los reportes del tablero |
| Captura y enroque manuales | Se ven todas las piezas en sus casillas finales; la app no valida legalidad |
| Luces `a1 h1 a8 h8` | Se iluminan las esquinas correctas |
| Luces `e2 e4` y apagar | Solo esas casillas, luego todas apagadas |
| Entrada `z9` | Alerta local, no se envía el comando |
| Desconectar | Desaparece la lectura vigente y se deshabilitan comandos |
| Apagar/encender Go y reconectar | Se recuperan lecturas nuevas, no una posición almacenada |
| Volver desde otra app | Si sigue conectado, solicita una lectura nueva |
| Exportar registro | El informe refleja el estado y permite inspeccionar TX/RX |

Si el Go solo reporta al mover, mover y devolver una pieza después de solicitar posición. Ante un fallo, exportar el registro antes de que roten los 200 eventos; anotar casillas esperadas/reales y los pasos para reproducirlo.

## Circuito de desarrollo

1. Modificar Connect.
2. Ejecutar `swift test` desde la raíz del paquete.
3. Ejecutar esta app en el iPhone y validar el cambio con hardware.
4. Actualizar la dependencia en Chess Dex y verificar su integración.

Para verificar solo compilación, desde la raíz del repo ChessBoardConnect:

```sh
xcodebuild -project Examples/ConnectTestApp/ConnectTestApp.xcodeproj \
  -scheme ConnectTestApp -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/connect-testapp-build CODE_SIGNING_ALLOWED=NO build
```

**Estado:** compilación para iPhone verificada; pruebas con Go físico pendientes. El contador, los logs y las capacidades sirven para diagnóstico, no certifican compatibilidad de firmware.
