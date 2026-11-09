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

1. **Cierra automáticamente** las apps de la lista `cerrarSiempre`. Primero les pide que cierren solas (como apretar la X) y solo fuerza lo que sigue vivo a los 2,5 segundos. Las listas aceptan comodines: `Adobe*` cierra AdobeIPCBroker, AdobeCollabSync, AcroTray y cualquier otra cosa que empiece con "Adobe".
2. **Te pregunta** por las apps de `preguntarAntes` (navegadores, Discord, Spotify...) **y además hace un barrido automático de procesos de fondo**: cualquier programa de terceros sin ventana visible que esté haciendo bulto aparece en el diálogo, aunque no esté en ninguna lista. Tus apps vienen tildadas; lo que encontró el barrido viene **destildado**: se cierra solo si lo elegís vos.
3. **Pausa servicios pesados de Windows** (SysMain, indexado de búsqueda, telemetría, cola de impresión).
4. **Pausa servicios de terceros** que matcheen `serviciosTercerosAuto`: updaters de Adobe/Google/Edge/LG, Bonjour, TeamViewer, etc.

5. **Corta las descargas en segundo plano que meten lag**: pausa Windows Update, Delivery Optimization (que sube actualizaciones a otras PCs usando TU internet) y BITS, y limpia la caché DNS.
6. **Activa el plan de energía Alto rendimiento** (en Equilibrado, Windows estaciona núcleos del CPU y eso genera micro-stutters).
7. **Purga la memoria standby** (ver abajo).
8. **Prioridad alta al juego** y, si lo pediste, **afinidad a los núcleos P** (ver "Solo P-cores").

Al final te dice cuánta RAM libre ganaste. Todo lo pausado se restaura con el botón **Restaurar todo** (incluido el plan de energía) o solo al reiniciar la PC.

## Auto-modo gaming 🎮

Tildá el toggle **Auto-gaming** (o poné `"autoGaming": true` en el config para que arranque prendido). Booster se entera de que abriste un juego de la lista `juegos` por un **evento de Windows**, sin recorrer procesos cada 5 segundos. Cuando lo detecta, dispara el modo gaming **silencioso**: hace todo lo de arriba pero sin mostrar diálogos (solo cierra la lista automática, no la de "preguntar"). Se rearma solo cuando cerrás el juego.

## Modo sigilo 🤫

Con un juego abierto (con o sin Auto-gaming), Booster **se calla**: deja de pinguear, de consultar la GPU y de dibujar gráficos, y su timer pasa de 1 a 5 segundos. Lo único que sigue es leer la RAM para la auto-purga. Un optimizador no debería ser una fuente de micro-cortes. Al cerrar el juego vuelve solo al monitoreo normal.

## Blindaje de servers 🛡️

Si en la misma PC hosteás cosas (un server de Counter, Minecraft, MU, un túnel Playit, una base de datos), Booster **nunca** las cierra ni las pausa: ni en modo gaming, ni desde el barrido de fondo, ni tildándolas a mano. Los procesos van en `servidores` y los servicios en `serviciosServidores` del config. En la lista de tragones aparecen en azul con la marca `SERVER`.

## Solo P-cores (CPUs híbridas) 🧠

En los Intel de 12ª generación en adelante hay núcleos P (rendimiento) y E (eficiencia). Windows 10 no los reparte bien y a veces manda hilos del juego a los E. El toggle **Solo P-cores** (solo aparece si tu CPU es híbrido) fija el juego a los núcleos P. Se aplica en el acto al juego abierto, así que **probalo**: prendelo y apagalo mirando los FPS mínimos. No sirve en todos los juegos y algunos anticheat (Vanguard) lo bloquean. Para dejarlo fijo: `"soloPCores": true` en el config, o por juego dentro de `perfiles`.

## Diagnóstico 🔎

La página **Diagnóstico** hace dos cosas, las dos de solo lectura:

- **Audita lo que de verdad mueve la aguja**: si el monitor está a los Hz que da, si la RAM corre con XMP/EXPO, plan de energía, modo de juego, GameDVR, aceleración del mouse, integridad de memoria, espacio en disco, y qué quedó pausado.
- **Mide antes y después**: *Medir base* toma 15 segundos del ruido de fondo de la PC (CPU que consume lo que no es el juego, tiempo en DPC/interrupciones de drivers, cambios de contexto, procesos, servicios, RAM libre, ping y jitter). Aplicás el modo gaming, tocás *Medir y comparar* y te dice métrica por métrica si quedó MEJOR, PEOR o igual. Diferencias de menos del 5% se marcan como ruido, no como mejora.

No mide FPS (eso lo ve mejor el contador del propio juego): mide lo que Booster puede cambiar.

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

El toggle **Timer 0,5 ms** pide la máxima precisión del timer de Windows mientras Booster esté abierto. Ya no se prende solo con el modo gaming: es opcional (`"timer05": true` en el config para que arranque prendido). Lo que hay que saber:

- **Windows 10 (2004 en adelante)**: el pedido vale solo para el proceso que lo hace. Medido en 22H2: con Booster pidiendo 0,5 ms, un `Sleep(1)` en otro proceso sigue tardando ~15 ms. No le llega al juego.
- **Windows 11**: por defecto pasa lo mismo, pero existe la clave `GlobalTimerResolutionRequests` que lo vuelve global. El botón **Timer global (Win11)** de la página Pro la activa con backup (pide reiniciar) y **Revertir tweaks** la deshace. Con la clave activa, el toggle sí le llega al juego.

Los juegos que necesitan timer fino ya piden 1 ms por su cuenta.

## Tweaks persistentes: Optimizar PC 🔧

Tres botones abajo del panel de servicios:

- **Optimizar PC** (se aplica una sola vez, con backup de cada valor original):
  - **Red**: desactiva el *algoritmo de Nagle* y el *delayed ACK* (Windows agrupa paquetes chicos antes de mandarlos; ojo: esto solo afecta a juegos que van por **TCP** — Valorant, CS2, Apex o LoL usan UDP y no lo notan) y el *throttling de red* que Windows aplica cuando reproducís audio/video. Si un valor ya está igual o mejor (por otro tweak previo), no lo toca.
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
- **Lo que hosteás**: servers de juegos, túneles, bases de datos, WSL/Docker, Tailscale (listas `servidores` y `serviciosServidores`).

Los servicios solo se **pausan**, nunca se deshabilitan: al reiniciar Windows vuelven solos. Los únicos cambios persistentes son los de **Optimizar PC** (valores de registro y ahorro de energía de dispositivos, todos documentados arriba), que guardan backup de los valores originales y se deshacen enteros con **Revertir tweaks**.

## Novedades v9 🛡️

- **Blindaje de servers**, **cierre amable** antes de forzar y barrido de fondo destildado por defecto.
- **Modo sigilo** mientras jugás y detección de juegos por evento en vez de sondeo.
- **Solo P-cores** para CPUs híbridas.
- **Página Diagnóstico** con medición antes/después.
- El ping en vivo ahora es asíncrono (ya no puede trabar la interfaz).
- **Interfaz renovada**: botones e interruptores con bordes suaves y estado al pasar el mouse, barra de título y listas en oscuro, ícono propio.
- **Arreglado**: al minimizar a la bandeja Booster se cerraba.
- **Se adapta a la pantalla**: se ve nítido con la escala de Windows al 125% o 150%, y si la ventana no entra (notebooks de 1366×768) se achica entera. Para forzar un tamaño: `"escalaUI": 0.85` (más chica) o `1.25` (más grande); `0` es automático.
- **Notebooks**: a batería el modo gaming no cambia el plan de energía y avisa; *Optimizar PC* pregunta antes de apagar el ahorro de energía de USB/red; Diagnóstico marca si estás desenchufado.
- El timer de 0,5 ms pasa a ser un toggle opcional, con **Timer global** para que en Windows 11 le llegue al juego.

## Novedades v8 ⚡

- **Auto-purga tipo ISLC**: toggle en Recursos; si la RAM libre baja del umbral (`autoPurgaLibreMB`), purga sola (máx. una vez cada 2 minutos) y lo marca en el gráfico. Viene apagada: con RAM de sobra no suma.
- **Bandeja del sistema**: al minimizar **o cerrar con la X**, Booster queda en los íconos ocultos al lado del reloj, con menú de click derecho (Modo gaming, Purgar, Restaurar, Salir de Booster). Auto-gaming y auto-purga siguen activos. Para cerrarlo de verdad: click derecho en el ícono > *Salir de Booster*. Si preferís que la X cierre, poné `"cerrarALaBandeja": false` en el config. Solo se abre una instancia a la vez.
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
| `perfiles` | Por juego, qué apps conservar (ej. Valorant conserva Discord) y, opcional, `"soloPCores": true` |
| `servidores` | Procesos que hosteás: **nunca** se cierran ni aparecen en el barrido |
| `serviciosServidores` | Servicios que hosteás: **nunca** se pausan |
| `autoGaming` / `soloPCores` / `timer05` | `true` para que el toggle arranque prendido |
| `escalaUI` | Tamaño de la interfaz: `0` automático, `0.85` más chica, `1.25` más grande |
| `cerrarALaBandeja` | `true`: la X manda a la bandeja; `false`: la X cierra |
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
