CLIPSVC.R4X
===========

CLIPSVC.R4X ist der Clipboard-Service.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\ClipboardService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\ClipboardService\zig-out\CLIPSVC.R4X

Contract:
- R4XStart-Entry: `clipsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`
- Service-Name: `CLIPSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\CLIPSVC.R4X`

