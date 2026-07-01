# ⚡ Booster

Optimizador gaming para Windows: cuando terminás de trabajar, un clic y tu PC queda lista para jugar sin input lag. Cierra apps en segundo plano, pausa servicios pesados (de Windows **y de terceros**) y te muestra qué está devorando tu RAM y CPU.

Sin instalación, sin dependencias: es un script de PowerShell con interfaz gráfica que corre en cualquier Windows 10/11.

## Instalación desde cero (si no tenés nada instalado)

**Opción fácil — sin instalar nada:**
1. En esta página de GitHub: botón verde **Code** → **Download ZIP**.
2. Extraé el ZIP donde quieras (ej: `C:\Booster`).
3. Doble clic en **`Booster.bat`** → aceptá el permiso de administrador → listo.

**Opción con git (para recibir actualizaciones con `git pull`):**
1. Abrí PowerShell y ejecutá:
   ```
   winget install Git.Git
   ```
   (`winget` ya viene con Windows 10/11; si no lo tenés, instalá "Instalador de aplicación" desde la Microsoft Store)
2. Cerrá y volvé a abrir PowerShell, después:
   ```
   git clone https://github.com/ValeenMar/booster.git
   cd booster
   ```
3. Doble clic en **`Booster.bat`**.

No hace falta instalar PowerShell ni nada más: Windows ya trae todo lo que Booster necesita.

## Qué hace el MODO GAMING

1. **Cierra automáticamente** las apps de la lista `cerrarSiempre`. Las listas aceptan comodines: `Adobe*` cierra AdobeIPCBroker, AdobeCollabSync, AcroTray y cualquier otra cosa que empiece con "Adobe".
2. **Te pregunta** por las apps de `preguntarAntes` (navegadores, Discord, Spotify...) **y además hace un barrido automático de procesos de fondo**: cualquier programa de terceros sin ventana visible que esté haciendo bulto aparece en el diálogo para que lo cierres, aunque no esté en ninguna lista. Destildás lo que quieras conservar.
3. **Pausa servicios pesados de Windows** (SysMain, indexado de búsqueda, telemetría, cola de impresión).
4. **Pausa servicios de terceros** que matcheen `serviciosTercerosAuto`: updaters de Adobe/Google/Edge/LG, Bonjour, TeamViewer, etc.

Al final te dice cuánta RAM libre ganaste. Todo lo pausado se restaura con el botón **Restaurar todo** o solo al reiniciar la PC.

Además:
- **Monitor de tragones**: lista de procesos ordenada por RAM con % de CPU real y una columna que marca cuáles corren de fondo sin ventana. Tildás y cerrás.
- **Panel de servicios**: muestra los servicios de Windows configurados + todos los servicios de terceros que detecta corriendo en tu PC. Podés pausar cualquiera tildándolo.

## Protecciones (importante)

Booster **nunca** toca, aunque los agregues a las listas por error:

- Procesos críticos de Windows (explorer, dwm, svchost...) y Windows Defender.
- **Anticheats**: Vanguard (vgc/vgk), EasyAntiCheat, BattlEye, FACEIT — si los matás no podés entrar al juego.
- **Drivers y software de periféricos**: NVIDIA, AMD, Realtek, Logitech G HUB, Razer, Corsair iCUE, SteelSeries — los necesitás mientras jugás.
- **ExitLag** y similares que usás para jugar.

Los servicios solo se **pausan**, nunca se deshabilitan: al reiniciar Windows vuelven solos. Booster no toca el registro ni hace cambios permanentes.

## Personalizarlo

Todo se configura editando **`config.json`** con cualquier editor de texto:

| Clave | Qué es |
|---|---|
| `cerrarSiempre` | Procesos que se cierran sin preguntar en modo gaming |
| `preguntarAntes` | Procesos por los que te pregunta antes de cerrar |
| `serviciosPausables` | Servicios de Windows que se pausan |
| `serviciosTercerosAuto` | Patrones de servicios de terceros que el modo gaming pausa solo |
| `serviciosProtegidos` | Servicios que **nunca** se pausan (anticheat, drivers, antivirus) |
| `protegidos` | Procesos que Booster **nunca** cierra |
| `umbralRamMB` | RAM mínima (MB) para aparecer en la lista de tragones |

Los nombres van **sin** `.exe` y aceptan comodines (`*`). Para saber el nombre de un proceso: Administrador de tareas → pestaña *Detalles*.

> Tip: agregá a `cerrarSiempre` los launchers y apps que VOS usás para trabajar. La gracia es que cada uno arma su propia lista.

## Requisitos

- Windows 10 u 11 (PowerShell 5.1 ya viene incluido).
- Permisos de administrador (solo para pausar/restaurar servicios).

---

Hecho para dejar de sufrir input lag después del laburo 🎮
