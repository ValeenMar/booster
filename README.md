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

5. **Corta las descargas en segundo plano que meten lag**: pausa Windows Update, Delivery Optimization (que sube actualizaciones a otras PCs usando TU internet) y BITS, y limpia la caché DNS.
6. **Activa el plan de energía Alto rendimiento** (en Equilibrado, Windows estaciona núcleos del CPU y eso genera micro-stutters) y **sube el timer del sistema a 0,5 ms** para mejor frame pacing.
7. **Purga la memoria standby** (ver abajo).

Al final te dice cuánta RAM libre ganaste. Todo lo pausado se restaura con el botón **Restaurar todo** (incluido el plan de energía) o solo al reiniciar la PC. El timer se libera al cerrar Booster.

## Auto-modo gaming 🎮

Tildá el checkbox **Auto-gaming** y Booster vigila cada 5 segundos si arrancó un juego de la lista `juegos` del config (Valorant, CS2, Fortnite, LoL, Apex y más — agregá los tuyos). Cuando lo detecta, dispara el modo gaming **silencioso**: hace todo lo de arriba pero sin mostrar diálogos, para no interrumpirte el juego (solo cierra la lista automática, no la de "preguntar"). Se rearma solo cuando cerrás el juego.

## Apps de inicio 🚀

El botón **Apps de inicio** abre un panel con todo lo que arranca junto con Windows (claves Run del registro y carpetas de Inicio). Destildás lo que no querés y aplicás. Usa la misma mecánica que el Administrador de tareas (claves *StartupApproved*): no borra nada, es 100% reversible desde el mismo panel o desde el propio Administrador de tareas. Menos cosas al arrancar = menos que limpiar después.

## Purgar RAM caché 🧹

La "memoria standby" es caché que Windows guarda por las dudas; cuando se llena, algunos juegos stutterean al pedir RAM. El botón **Purgar RAM caché** la vacía al instante (lo mismo que hace ISLC), y el modo gaming la purga automáticamente después de cerrar procesos. Es inofensivo: Windows la vuelve a llenar sola con el uso.

## Dashboard con gráfico en vivo 📈

La interfaz es un dashboard oscuro (paleta [Catppuccin Mocha](https://catppuccin.com/)) con:

- **Gráfico de RAM en tiempo real** (últimos 3 minutos, 1 muestra por segundo): la escala hace zoom al rango real de uso, así cuando purgás o cerrás procesos **ves el bajón en vivo**. Cada purga queda marcada con una línea verde y los GB que liberó.
- **Tarjetas de métricas**: RAM en uso, RAM libre, % de carga (se pone amarillo/rojo si va justa) y total purgado en la sesión.
- Lectura de memoria vía API nativa (`GlobalMemoryStatusEx`), sin el costo de WMI: el monitoreo no consume nada apreciable.

## Timer de 0,5 ms ⏱️

El timer por defecto de Windows corre a 15,6 ms; con el checkbox **Timer 0,5 ms** (arriba a la derecha) Booster lo fuerza a la máxima precisión, igual que herramientas como TimerResolution o ISLC. Mejora el frame pacing y la consistencia de frames en varios juegos. Es riesgo cero: dura solo mientras Booster esté abierto — al cerrarlo, Windows lo devuelve al valor normal automáticamente. El modo gaming lo activa solo (dejá Booster abierto mientras jugás).

## Tweaks persistentes: Optimizar PC 🔧

Tres botones abajo del panel de servicios:

- **Optimizar PC** (se aplica una sola vez, con backup de cada valor original):
  - **Red**: desactiva el *algoritmo de Nagle* y el *delayed ACK* (Windows agrupa paquetes chicos antes de mandarlos: bueno para descargas, malo para el ping) y el *throttling de red* que Windows aplica cuando reproducís audio/video. Si un valor ya está igual o mejor (por otro tweak previo), no lo toca.
  - **GameDVR / Game Bar**: Windows graba gameplay en segundo plano *por defecto* para el "grabar últimos 30 segundos" — eso es GPU trabajando en algo que no es tu juego. Se desactiva.
  - **Ahorro de energía de red y USB**: Windows apaga la placa de red y los puertos USB para ahorrar energía, lo que mete picos de latencia y afecta el polling del mouse. Se desactiva en la NIC activa y los dispositivos USB.
- **Revertir tweaks**: deshace TODO usando los backups (`.booster_net_backup.json` y `.booster_tweaks.json`) y restaura los valores exactos que tenías.
- **Test ping**: mide latencia promedio, mínima, máxima y jitter contra 1.1.1.1 y 8.8.8.8. Ideal para comparar antes y después.

Los cambios de registro terminan de aplicarse al reiniciar la PC.

**Qué esperar, siendo honestos**: estos tweaks eliminan las fuentes *locales* de latencia (descargas de fondo, buffering de paquetes, throttling). Suelen bajar algunos ms y sobre todo estabilizar el jitter y los picos de lag. Lo que NO pueden hacer es acortar la distancia física a los servidores del juego ni arreglar una conexión mala del proveedor — para eso no hay software que valga.

Este es el único módulo que toca el registro de Windows (3 valores, documentados y con backup). El resto de Booster sigue sin hacer cambios permanentes.

Además:
- **Monitor de tragones**: lista de procesos ordenada por RAM con % de CPU real y una columna que marca cuáles corren de fondo sin ventana. Tildás y cerrás.
- **Panel de servicios**: muestra los servicios de Windows configurados + todos los servicios de terceros que detecta corriendo en tu PC. Podés pausar cualquiera tildándolo.

## Protecciones (importante)

Booster **nunca** toca, aunque los agregues a las listas por error:

- Procesos críticos de Windows (explorer, dwm, svchost...) y Windows Defender.
- **Anticheats**: Vanguard (vgc/vgk), EasyAntiCheat, BattlEye, FACEIT — si los matás no podés entrar al juego.
- **Drivers y software de periféricos**: NVIDIA, AMD, Realtek, Logitech G HUB, Razer, Corsair iCUE, SteelSeries — los necesitás mientras jugás.
- **ExitLag** y similares que usás para jugar.

Los servicios solo se **pausan**, nunca se deshabilitan: al reiniciar Windows vuelven solos. Los únicos cambios persistentes son los de **Optimizar PC** (valores de registro y ahorro de energía de dispositivos, todos documentados arriba), que guardan backup de los valores originales y se deshacen enteros con **Revertir tweaks**.

## Novedades v8 ⚡

- **Auto-purga tipo ISLC**: toggle en Recursos; si la RAM libre baja del umbral (`autoPurgaLibreMB`), purga sola (máx. una vez cada 2 minutos) y lo marca en el gráfico.
- **Bandeja del sistema**: minimizá y Booster queda al lado del reloj con menú de click derecho (Modo gaming, Purgar, Restaurar, Salir). Timer, auto-gaming y auto-purga siguen activos.
- **Prioridad de CPU alta al juego**: el modo gaming (manual o automático) le sube la prioridad al juego detectado, como harías en el Administrador de tareas. Booster además baja su propia prioridad para no molestar.
- **Ping en vivo**: segundo gráfico en Recursos con la latencia a 1.1.1.1 segundo a segundo y el jitter — ves los picos de lag en el momento.
- **Tarjetas de GPU y VRAM** (si tenés NVIDIA, vía `nvidia-smi`): uso, temperatura y VRAM.
- **Perfiles por juego** (`perfiles` en el config): ej. Valorant conserva Discord y WhatsApp aunque estén en la lista de cierre.
- **Modo trabajo** (en Pro): restaura todo y abre tus apps de laburo (`abrirEnTrabajo` en el config: rutas o nombres de .exe).
- **Limpiar basura** (en Pro): temporales de Windows + cachés de shaders viejos (DirectX/NVIDIA).
- **Avisador de updates**: al abrir, Booster compara su versión contra este repo y te avisa si hay una nueva.

## 🚨 Booster Rescate — cuenta de Discord que manda spam sola

Si una cuenta empieza a mandar sola mensajes de "regalo de MrBeast", casinos cripto o Nitro gratis, **no le adivinaron la contraseña: le robaron el token de sesión**. El token es la llave que prueba que ya iniciaste sesión, así que el atacante entra sin contraseña y el 2FA no lo frena.

Ejecutá **`Rescate.bat`** (o el botón *Rescate antimalware* en la página Pro de Booster). Busca las mañas concretas de esta familia de malware:

| Qué revisa | Por qué |
|---|---|
| `index.js` del cliente de Discord | El truco estrella: lo parchean para robar el token cada vez que abrís Discord. Se compara contra el contenido legítimo exacto |
| Exclusiones y estado de Defender | El malware se auto-excluye del antivirus o lo apaga |
| Arranque de Windows (Run, RunOnce, carpetas de Inicio) | Persistencia. Solo marca lo que está **sin firma digital** en carpetas de usuario |
| Tareas programadas | Solo las que tienen comando codificado (`-enc`) o descarga en línea: una tarea normal con `-File` no se toca |
| Procesos corriendo | Solo desde Temp o sueltos en la raíz de AppData, que es el patrón del dropper |
| Webhooks de Discord dentro de archivos | Por ahí se manda el token robado. Un **ejecutable** con un webhook adentro es casi siempre un stealer |
| Archivo `hosts` y persistencia WMI | Bloqueo de antivirus y ejecución oculta |

**Nada se borra**: todo va a la carpeta `Cuarentena` con un manifiesto JSON, y el botón *Restaurar cuarentena* deshace la limpieza completa. Nunca toca nada dentro de `C:\Windows`.

### El orden importa (y casi todos lo hacen al revés)

1. Cerrar Discord del todo.
2. **Limpiar la PC primero** (esta herramienta + escaneo de Defender). Si cambiás la contraseña con el ladrón todavía corriendo, se roba el token nuevo.
3. Reiniciar.
4. **Recién ahí**, cambiar la contraseña **desde otro dispositivo** (el celular) y marcar "cerrar sesión en todos los dispositivos". Eso es lo que invalida el token robado.
5. Activar 2FA, revisar *Aplicaciones autorizadas* y sacar lo desconocido.

El botón **Guía de la cuenta** tiene los pasos completos adentro de la app.

> Si el escaneo no encuentra nada, es probable que el token se lo hayan sacado sin infectar la PC (páginas truchas de "Nitro gratis", QR falsos). Los pasos 4 y 5 siguen siendo exactamente lo que hay que hacer.

**No es un antivirus completo**: es un cazador dirigido a esta amenaza. Corré igual el escaneo de Microsoft Defender (y para casos jodidos, el *Examen sin conexión*, que escanea antes de que arranque Windows).

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
| `juegos` | Procesos de juegos que disparan el auto-modo gaming y reciben prioridad alta |
| `perfiles` | Por juego, qué apps conservar (ej. Valorant conserva Discord) |
| `abrirEnTrabajo` | Apps que abre el botón Modo trabajo (rutas o nombres de .exe) |
| `autoPurgaLibreMB` | Umbral de RAM libre (MB) que dispara la auto-purga |
| `umbralRamMB` | RAM mínima (MB) para aparecer en la lista de tragones |

Los nombres van **sin** `.exe` y aceptan comodines (`*`). Para saber el nombre de un proceso: Administrador de tareas → pestaña *Detalles*.

> Tip: agregá a `cerrarSiempre` los launchers y apps que VOS usás para trabajar. La gracia es que cada uno arma su propia lista.

## Requisitos

- Windows 10 u 11 (PowerShell 5.1 ya viene incluido).
- Permisos de administrador (solo para pausar/restaurar servicios).

---

Hecho para dejar de sufrir input lag después del laburo 🎮
