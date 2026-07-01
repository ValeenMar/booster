# ⚡ Booster

Optimizador gaming para Windows: cuando terminás de trabajar, un clic y tu PC queda lista para jugar sin input lag. Cierra las apps en segundo plano, pausa servicios pesados y te muestra qué está devorando tu RAM y CPU.

Sin instalación, sin dependencias: es un script de PowerShell con interfaz gráfica que corre en cualquier Windows 10/11.

## Cómo usarlo

1. Descargá o cloná este repo:
   ```
   git clone https://github.com/TU_USUARIO/booster.git
   ```
2. Doble clic en **`Booster.bat`**.
3. Aceptá el permiso de administrador (lo necesita para pausar servicios).
4. Tocá **MODO GAMING** y listo.

## Qué hace el MODO GAMING

1. **Cierra automáticamente** las apps de la lista `cerrarSiempre` (OneDrive, Teams, Slack, etc. — cosas de trabajo que no querés mientras jugás).
2. **Te pregunta** por las apps de `preguntarAntes` (navegadores, Discord, Spotify...): te muestra cuáles están abiertas y destildás las que quieras dejar. Así no te cierra el Discord si estás en llamada.
3. **Pausa servicios pesados** de Windows (SysMain, indexado de búsqueda, telemetría, cola de impresión). Se restauran con el botón *Restaurar servicios* o solos al reiniciar la PC.

Además tenés un monitor de **procesos tragones**: la lista muestra qué procesos consumen más RAM y CPU en tiempo real; tildás los que quieras y los cerrás con un botón. Los que están muy pasados de rosca aparecen en rojo.

## Personalizarlo

Todo se configura editando **`config.json`** con cualquier editor de texto:

| Clave | Qué es |
|---|---|
| `cerrarSiempre` | Procesos que se cierran sin preguntar en modo gaming |
| `preguntarAntes` | Procesos por los que te pregunta antes de cerrar |
| `serviciosPausables` | Servicios de Windows que se pausan |
| `protegidos` | Procesos que Booster **nunca** va a tocar (no saques nada de acá si no sabés qué es) |
| `umbralRamMB` | RAM mínima (en MB) para que un proceso aparezca en la lista de tragones |

Los nombres de proceso van **sin** `.exe`. Para saber el nombre de un proceso: Administrador de tareas → pestaña *Detalles*.

> Tip: agregá a `cerrarSiempre` los launchers y apps que VOS usás para trabajar. La gracia es que cada uno arma su propia lista.

## Seguridad

- Booster tiene una lista de procesos protegidos (explorer, dwm, svchost, Windows Defender...) que no cierra bajo ninguna circunstancia, aunque los agregues a las listas.
- Los servicios solo se **pausan**, no se deshabilitan: al reiniciar Windows vuelven solos.
- No toca el registro ni modifica nada permanente.

## Requisitos

- Windows 10 u 11 (PowerShell 5.1 ya viene incluido).
- Permisos de administrador (solo para pausar/restaurar servicios).

---

Hecho para dejar de sufrir input lag después del laburo 🎮
