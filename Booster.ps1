# ============================================================
#  BOOSTER v9 - Optimizador gaming para despues del trabajo
#  - v9: blindaje de servers (nunca cierra ni pausa lo que hosteas),
#    cierre amable antes de forzar, modo sigilo mientras jugas,
#    deteccion de juegos por evento, afinidad a P-cores en CPUs
#    hibridas y pagina Diagnostico con medicion antes/despues.
#    El timer de 0.5 ms queda como toggle opcional: desde Windows 10
#    2004 es por proceso; en Windows 11 llega al juego con la clave
#    global (boton 'Timer global' de la pagina Pro).
#  - Listas con comodines (Adobe* cierra todo lo de Adobe)
#  - Barrido de procesos de fondo sin ventana
#  - Pausa servicios de Windows Y de terceros (updaters, etc.)
#  - Protege anticheats, drivers de GPU/audio/perifericos
#  - Modulo de red: menos latencia (Nagle, throttling, DNS)
#  - Tweaks persistentes con backup: GameDVR off y ahorro de
#    energia de NIC/USB off; un boton para revertir todo
#  - Plan de energia Alto rendimiento en modo gaming
#  - Gestor de apps de inicio (misma mecanica que el Adm. de tareas)
#  - Purga de memoria standby estilo ISLC
#  - Auto-modo gaming: detecta juegos y se activa solo (silencioso)
#  - Dashboard Catppuccin Mocha con grafico de RAM en tiempo real:
#    las purgas se marcan en verde y se ve el bajon en vivo
#  - v8: auto-purga tipo ISLC, bandeja del sistema, prioridad CPU
#    alta al juego, ping en vivo, stats de GPU, perfiles por juego,
#    modo trabajo, limpieza de basura y avisador de updates
# ============================================================
#Requires -Version 5.1

# --- Auto-elevación (necesaria para pausar servicios) -------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Nitidez con escala de Windows (125%, 150%...): sin esto Windows estira la
# ventana como una foto y se ve borrosa. Tiene que ir antes de crear ventanas;
# el tamaño real lo ajusta después Invoke-UiScale.
try {
    Add-Type -Name Dpi -Namespace BoosterNative -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][BoosterNative.Dpi]::SetProcessDPIAware()
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Una sola instancia: si Booster ya está abierto (seguramente en la bandeja),
# no se abre otro encima.
$creado = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\BoosterGamingApp', [ref]$creado)
if (-not $creado) {
    [System.Windows.Forms.MessageBox]::Show("Booster ya está abierto.`nBuscalo en los íconos ocultos, al lado del reloj (doble clic para mostrarlo).", 'Booster', 'OK', 'Information') | Out-Null
    exit
}

# Timer de alta precisión (opcional, toggle "Timer 0,5 ms").
# Ojo: desde Windows 10 2004 el pedido vale solo para el proceso que lo hace;
# para que le llegue al juego hace falta Windows 11 + la clave global.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BoosterTimer {
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(out uint min, out uint max, out uint current);
    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(uint desired, bool set, out uint current);

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_POWER_THROTTLING_STATE { public uint Version; public uint ControlMask; public uint StateMask; }
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetProcessInformation(IntPtr h, int cls, ref PROCESS_POWER_THROTTLING_STATE info, int size);

    // Windows 11 ignora el pedido de timer de un proceso con la ventana
    // minimizada u oculta (Booster en la bandeja). Esto le pide que lo respete igual.
    public static bool KeepWhenHidden() {
        try {
            PROCESS_POWER_THROTTLING_STATE s = new PROCESS_POWER_THROTTLING_STATE();
            s.Version = 1; s.ControlMask = 0x4; s.StateMask = 0;   // IGNORE_TIMER_RESOLUTION apagado
            return SetProcessInformation(GetCurrentProcess(), 4, ref s, Marshal.SizeOf(typeof(PROCESS_POWER_THROTTLING_STATE)));
        } catch { return false; }
    }
}
"@

# Topología del CPU: en los híbridos (Intel 12ª gen en adelante) separa
# núcleos P (rendimiento) de E (eficiencia) para poder fijar el juego a los P
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BoosterCpu {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetLogicalProcessorInformationEx(int rel, IntPtr buf, ref uint len);

    static int Bits(long v) { int n = 0; ulong u = (ulong)v; while (u != 0) { n += (int)(u & 1); u >>= 1; } return n; }

    // Devuelve [mascaraP, mascaraTodos, nucleosP, nucleosE]; mascaraP = 0 si el CPU no es híbrido
    public static long[] Query() {
        uint len = 0;
        GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref len);
        if (len == 0) return new long[] { 0, 0, 0, 0 };
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetLogicalProcessorInformationEx(0, buf, ref len)) return new long[] { 0, 0, 0, 0 };
            List<long> masks = new List<long>();
            List<int> eff = new List<int>();
            int off = 0;
            while (off < (int)len) {
                int size = Marshal.ReadInt32(buf, off + 4);
                if (size <= 0) break;
                // PROCESSOR_RELATIONSHIP: Flags(8) EfficiencyClass(9) ... GroupMask[0].Mask(32) Group(40)
                if (Marshal.ReadInt16(buf, off + 40) == 0) {
                    masks.Add(Marshal.ReadInt64(buf, off + 32));
                    eff.Add(Marshal.ReadByte(buf, off + 9));
                }
                off += size;
            }
            long all = 0; int maxEff = 0, minEff = 255; bool haySmt = false, hayNoSmt = false;
            for (int i = 0; i < masks.Count; i++) {
                all |= masks[i];
                if (eff[i] > maxEff) maxEff = eff[i];
                if (eff[i] < minEff) minEff = eff[i];
                if (Bits(masks[i]) > 1) haySmt = true; else hayNoSmt = true;
            }
            long p = 0; int np = 0;
            if (maxEff != minEff) {
                // Windows informa la clase de eficiencia: los P son la clase más alta
                for (int i = 0; i < masks.Count; i++) if (eff[i] == maxEff) { p |= masks[i]; np++; }
            } else if (haySmt && hayNoSmt) {
                // Sin clase informada: en Alder/Raptor Lake los P tienen 2 hilos y los E, 1
                for (int i = 0; i < masks.Count; i++) if (Bits(masks[i]) > 1) { p |= masks[i]; np++; }
            }
            return new long[] { p, all, np, (p == 0 ? 0 : masks.Count - np) };
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
"@

# Aviso de arranque de procesos por evento de WMI: Booster se entera de que
# abriste un juego sin tener que recorrer la lista de procesos cada 5 segundos.
# Corre en un hilo aparte y deja los nombres en una cola que lee el timer.
try {
    Add-Type -ReferencedAssemblies 'System', 'System.Management' -TypeDefinition @"
using System;
using System.Management;
using System.Diagnostics;
using System.Collections.Generic;
public static class BoosterWatch {
    static ManagementEventWatcher w;
    static readonly object gate = new object();
    static List<string> pend = new List<string>();
    public static bool Start() {
        try {
            w = new ManagementEventWatcher(new WqlEventQuery("SELECT ProcessID FROM Win32_ProcessStartTrace"));
            w.EventArrived += OnStart;
            w.Start();
            return true;
        } catch { return false; }
    }
    static void OnStart(object s, EventArrivedEventArgs e) {
        try {
            int pid = Convert.ToInt32(e.NewEvent["ProcessID"]);
            string n = Process.GetProcessById(pid).ProcessName;
            lock (gate) { if (pend.Count < 500) pend.Add(n); }
        } catch { }
        finally { try { e.NewEvent.Dispose(); } catch { } }
    }
    public static string[] Drain() {
        lock (gate) { string[] r = pend.ToArray(); pend.Clear(); return r; }
    }
    public static void Stop() {
        try { if (w != null) { w.Stop(); w.Dispose(); w = null; } } catch { }
    }
}
"@
    $script:WatchDisponible = $true
} catch { $script:WatchDisponible = $false }

# API nativa para purgar la lista standby de memoria (estilo ISLC)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BoosterMem {
    // Pack = 1 es obligatorio: sin eso .NET mete 4 bytes de relleno,
    // Windows lee la estructura corrida, el privilegio no se habilita
    // y la purga falla con 0xC0000061 aunque el proceso sea admin
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr rel);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int cls, ref int info, int len);

    const int SE_PRIVILEGE_ENABLED = 2;
    const int TOKEN_QUERY = 8;
    const int TOKEN_ADJUST_PRIVILEGES = 32;
    const int SystemMemoryListInformation = 80;
    const int MemoryPurgeStandbyList = 4;

    static void EnablePrivilege(string priv) {
        IntPtr tok = IntPtr.Zero;
        TokPriv1Luid tp = new TokPriv1Luid();
        tp.Count = 1; tp.Luid = 0; tp.Attr = SE_PRIVILEGE_ENABLED;
        OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref tok);
        LookupPrivilegeValue(null, priv, ref tp.Luid);
        AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }

    public static int PurgeStandbyList() {
        EnablePrivilege("SeProfileSingleProcessPrivilege");
        int cmd = MemoryPurgeStandbyList;
        return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, 4);
    }
}
"@

# API nativa para leer la RAM cada segundo sin el costo de WMI
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BoosterRam {
    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX {
        public uint dwLength; public uint dwMemoryLoad;
        public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile;
        public ulong ullTotalVirtual; public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX b);
    // Devuelve [totalMB, disponibleMB, cargaPct]
    public static long[] Query() {
        MEMORYSTATUSEX m = new MEMORYSTATUSEX();
        m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        GlobalMemoryStatusEx(ref m);
        return new long[] { (long)(m.ullTotalPhys / 1048576), (long)(m.ullAvailPhys / 1048576), (long)m.dwMemoryLoad };
    }
}
"@

# Booster no compite con tus juegos: baja su propia prioridad de CPU
try { (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}

# --- Configuración -------------------------------------------
$script:BoosterVersion = 9
$script:MedicionesPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '.booster_mediciones.json'
$script:Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $Dir 'config.json'
$script:StatePath     = Join-Path $Dir '.booster_state.json'
$script:NetBackupPath = Join-Path $Dir '.booster_net_backup.json'
$script:TweaksPath    = Join-Path $Dir '.booster_tweaks.json'

# Todas las listas de procesos/servicios aceptan comodines: 'Adobe*'
$defaultConfig = [ordered]@{
    cerrarSiempre       = @('OneDrive','Teams','ms-teams','Slack','Zoom','Skype','Dropbox','GoogleDriveFS','Adobe*','Acro*','CCX*','Creative Cloud*','CoreSync','Copilot','Widgets','PhoneExperienceHost','YourPhone')
    preguntarAntes      = @('chrome','msedge','firefox','brave','opera','Discord','Spotify','WhatsApp','Telegram','steam','EpicGamesLauncher','Battle.net','RiotClient*','GalaxyClient*','Parsec')
    serviciosPausables  = @('SysMain','WSearch','DiagTrack','Spooler','BITS','DoSvc','wuauserv')
    serviciosTercerosAuto = @('Adobe*','AGSService','AGMService','*Update*','*update*','gupdate*','edgeupdate*','Bonjour*','TeamViewer*','AnyDesk*','SQLWriter','ClickToRunSvc')
    serviciosProtegidos = @('WinDefend','WdNisSvc','MDCoreSvc','Sense','*Defender*','Nv*','NVDisplay*','AMD*','Rtk*','Realtek*','*Audio*','vgc','vgk','EasyAntiCheat*','BEService*','FACEIT*','ESEA*','ExitLag*','Cowork*','Claude*')
    protegidos          = @('explorer','dwm','csrss','winlogon','services','lsass','svchost','System','Idle','Registry','smss','wininit','fontdrvhost','sihost','ctfmon','conhost','RuntimeBroker','ShellExperienceHost','StartMenuExperienceHost','SearchHost','TextInputHost','ApplicationFrameHost','SecurityHealth*','MsMpEng','NisSrv','audiodg','taskhostw','WmiPrvSE','dllhost','powershell','pwsh','WindowsTerminal','cmd','OpenConsole','msedgewebview2','claude*','Cowork*','nv*','NVIDIA*','amd*','Radeon*','Rtk*','Realtek*','lghub*','Logi*','Razer*','iCUE*','Corsair*','SteelSeries*','EasyAntiCheat*','BEService*','vgc','vgk','vgtray','vanguard*','FACEIT*','ExitLag*')
    juegos              = @('VALORANT*','cs2','csgo','r5apex*','FortniteClient*','League of Legends*','RocketLeague*','Overwatch*','GTA5*','RDR2*','dota2','deadlock*','EscapeFromTarkov*','FiveM*','Minecraft*')
    perfiles            = @(
        @{ juego = 'VALORANT*'; conservar = @('Discord','WhatsApp') }
    )
    abrirEnTrabajo      = @()
    autoPurgaLibreMB    = 3072
    umbralRamMB         = 100
    # v9 - Blindaje: lo que hosteás. Booster NUNCA cierra estos procesos ni
    # pausa estos servicios, ni en modo gaming ni a mano desde las listas.
    servidores          = @('hlds*','srcds*','java','playit*','MUnique*','OpenMU*','dotnet','postgres*','pg_ctl','mysqld*','mariadbd*','docker*','com.docker*','wsl*','vmmem*','tailscale*','node','python*','nginx','caddy','cloudflared','sshd','n8n*')
    serviciosServidores = @('Tailscale*','WSL*','WslInstaller','LxssManager','vmcompute','vmms','postgresql*','MySQL*','MariaDB*','playit*','docker*','com.docker*','sshd','LGHUB*')
    autoGaming          = $false   # arrancar con Auto-gaming ya encendido
    soloPCores          = $false   # arrancar con Solo P-cores ya encendido (CPUs híbridas)
    timer05             = $false   # arrancar con Timer 0,5 ms ya encendido
    cerrarALaBandeja    = $true    # la X manda a la bandeja en vez de cerrar
    escalaUI            = 0        # 0 = automática; ej. 0.85 más chica, 1.25 más grande
}

if (Test-Path $ConfigPath) {
    try {
        $script:Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show("config.json tiene un error de formato, se usa la configuración por defecto.`n$($_.Exception.Message)", 'Booster', 'OK', 'Warning') | Out-Null
        $script:Config = [pscustomobject]$defaultConfig
    }
} else {
    $defaultConfig | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
    $script:Config = [pscustomobject]$defaultConfig
}
# Si el config es de una versión anterior, completar claves nuevas
foreach ($k in $defaultConfig.Keys) {
    if ($Config.PSObject.Properties.Name -notcontains $k) {
        $Config | Add-Member -NotePropertyName $k -NotePropertyValue $defaultConfig[$k]
    }
}

# --- Paleta de colores (Catppuccin Mocha) --------------------
$colBg      = [System.Drawing.Color]::FromArgb(17, 17, 27)     # crust: fondo de ventana
$colPanel   = [System.Drawing.Color]::FromArgb(30, 30, 46)     # base: paneles, listas, tarjetas
$colSurface = [System.Drawing.Color]::FromArgb(49, 50, 68)     # surface0: grilla, botones neutros
$colAccent  = [System.Drawing.Color]::FromArgb(203, 166, 247)  # mauve
$colGreen   = [System.Drawing.Color]::FromArgb(166, 227, 161)
$colRed     = [System.Drawing.Color]::FromArgb(243, 139, 168)
$colYellow  = [System.Drawing.Color]::FromArgb(249, 226, 175)
$colBlue    = [System.Drawing.Color]::FromArgb(137, 180, 250)
$colTeal    = [System.Drawing.Color]::FromArgb(148, 226, 213)
$colText    = [System.Drawing.Color]::FromArgb(205, 214, 244)
$colDim     = [System.Drawing.Color]::FromArgb(147, 153, 178)
$colDark    = [System.Drawing.Color]::FromArgb(17, 17, 27)     # texto sobre botones pastel

# --- Helpers de lógica ----------------------------------------
function Test-InList([string]$name, $patterns) {
    foreach ($p in @($patterns)) {
        if ($name -like $p) { return $true }
    }
    return $false
}

function Test-Servidor([string]$name) {
    # Lo que hosteás (Counter, MU, Minecraft, Playit, bases de datos...)
    return (Test-InList $name $Config.servidores)
}

function Test-Intocable([string]$name) {
    return ((Test-InList $name $Config.protegidos) -or (Test-Servidor $name))
}

function Get-FreeRamMB {
    [Math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
}

function Get-ProcessSnapshot {
    # Dos muestras separadas ~900ms para calcular % de CPU real
    $t1 = @{}
    foreach ($p in (Get-Process)) {
        try { $t1[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {}
    }
    Start-Sleep -Milliseconds 900
    $grupos = @{}
    foreach ($p in (Get-Process)) {
        if ($p.Id -eq $PID) { continue }
        if (Test-InList $p.Name $Config.protegidos) { continue }
        $cpuMs = 0
        try {
            if ($t1.ContainsKey($p.Id)) { $cpuMs = $p.TotalProcessorTime.TotalMilliseconds - $t1[$p.Id] }
        } catch {}
        if (-not $grupos.ContainsKey($p.Name)) {
            $grupos[$p.Name] = [pscustomobject]@{ Name = $p.Name; Count = 0; RamMB = 0.0; CpuMs = 0.0; TieneVentana = $false; EsServidor = (Test-Servidor $p.Name) }
        }
        $g = $grupos[$p.Name]
        $g.Count++
        $g.RamMB += $p.WorkingSet64 / 1MB
        $g.CpuMs += [Math]::Max(0, $cpuMs)
        if ($p.MainWindowHandle -ne 0) { $g.TieneVentana = $true }
    }
    $cores = [Environment]::ProcessorCount
    foreach ($g in $grupos.Values) {
        $g | Add-Member -NotePropertyName CpuPct -NotePropertyValue ([Math]::Round($g.CpuMs / 900 / $cores * 100, 1))
    }
    $grupos.Values | Where-Object { $_.RamMB -ge $Config.umbralRamMB -or $_.CpuPct -ge 2 } | Sort-Object RamMB -Descending
}

function Get-RunningMatches($patterns) {
    # Grupos de procesos corriendo que matchean la lista (con comodines)
    Get-Process | Where-Object {
        $_.Id -ne $PID -and
        (Test-InList $_.Name $patterns) -and
        -not (Test-Intocable $_.Name)
    } | Group-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            RamMB = [Math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        }
    }
}

function Get-BackgroundApps {
    # Procesos de terceros SIN ventana visible: el "bulto" invisible.
    # Excluye protegidos y lo que ya está en las otras listas.
    $winDir = $env:WINDIR
    Get-Process | Where-Object {
        $_.Id -ne $PID -and $_.Path -and $_.Path -notlike "$winDir*" -and
        -not (Test-Intocable $_.Name) -and
        -not (Test-InList $_.Name $Config.cerrarSiempre) -and
        -not (Test-InList $_.Name $Config.preguntarAntes)
    } | Group-Object Name | ForEach-Object {
        $conVentana = ($_.Group | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0
        if (-not $conVentana) {
            [pscustomobject]@{
                Name  = $_.Name
                RamMB = [Math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
            }
        }
    } | Where-Object { $_.RamMB -ge 30 }
}

function Get-ThirdPartyServices {
    # Servicios corriendo cuyo ejecutable NO está en C:\Windows,
    # menos los protegidos (anticheat, drivers, antivirus...)
    $winDir = $env:WINDIR
    Get-CimInstance Win32_Service -Filter "State='Running'" | Where-Object {
        $path = if ($_.PathName) { $_.PathName.Trim('"') } else { '' }
        $path -and $path -notlike "$winDir*" -and
        -not (Test-ServicioIntocable $_.Name $_.DisplayName)
    }
}

function Test-ServicioIntocable([string]$name, [string]$display = '') {
    foreach ($lista in @($Config.serviciosProtegidos, $Config.serviciosServidores)) {
        if (Test-InList $name $lista) { return $true }
        if ($display -and (Test-InList $display $lista)) { return $true }
    }
    return $false
}

function Close-ProcessesByName([string[]]$names) {
    # Cierre en dos tiempos: primero se le pide a cada app que cierre sola
    # (como apretar la X: guarda sesión, no corrompe perfiles) y recién lo
    # que sigue vivo después de la espera se mata a la fuerza.
    $objetivo = @()
    foreach ($name in @($names | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Servidor $name) {
            Write-Log "Blindado (server): $name no se toca." 'warn'
            continue
        }
        if (Test-InList $name $Config.protegidos) {
            Write-Log "Ignorado (protegido): $name" 'warn'
            continue
        }
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        $objetivo += [pscustomobject]@{
            Name  = $name
            RamMB = [Math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        }
        foreach ($p in $procs) {
            if ($p.MainWindowHandle -ne 0) { try { [void]$p.CloseMainWindow() } catch {} }
        }
    }
    if ($objetivo.Count -eq 0) { return }

    $limite = (Get-Date).AddMilliseconds(2500)
    while ((Get-Date) -lt $limite) {
        $vivos = @($objetivo | Where-Object { Get-Process -Name $_.Name -ErrorAction SilentlyContinue })
        if ($vivos.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.Application]::DoEvents()
    }
    foreach ($o in $objetivo) {
        if (Get-Process -Name $o.Name -ErrorAction SilentlyContinue) {
            Stop-Process -Name $o.Name -Force -ErrorAction SilentlyContinue
            Write-Log "Cerrado (forzado): $($o.Name) (~$($o.RamMB) MB)" 'ok'
        } else {
            Write-Log "Cerrado: $($o.Name) (~$($o.RamMB) MB)" 'ok'
        }
    }
}

function Close-ProcessByName([string]$name) { Close-ProcessesByName @($name) }

function Get-State {
    # Estado de lo que Booster pausó/cambió en esta sesión (para restaurar).
    # Soporta el formato viejo (lista simple de servicios).
    $vacio = [pscustomobject]@{ servicios = @(); planEnergiaPrevio = $null }
    if (-not (Test-Path $StatePath)) { return $vacio }
    try {
        $raw = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($raw -is [string] -or $raw -is [array]) {
            return [pscustomobject]@{ servicios = @($raw); planEnergiaPrevio = $null }
        }
        if ($raw.PSObject.Properties.Name -notcontains 'servicios') {
            $raw | Add-Member -NotePropertyName servicios -NotePropertyValue @()
        } else {
            $raw.servicios = @($raw.servicios | Where-Object { $_ })
        }
        if ($raw.PSObject.Properties.Name -notcontains 'planEnergiaPrevio') {
            $raw | Add-Member -NotePropertyName planEnergiaPrevio -NotePropertyValue $null
        }
        return $raw
    } catch { return $vacio }
}

function Save-State($state) {
    if (@($state.servicios).Count -eq 0 -and -not $state.planEnergiaPrevio) {
        if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
        return
    }
    ConvertTo-Json -InputObject $state -Depth 4 | Set-Content $StatePath -Encoding UTF8
}

function Add-StoppedToState([string[]]$names) {
    $state = Get-State
    $state.servicios = @(@($state.servicios) + $names | Select-Object -Unique)
    Save-State $state
}

function Stop-ServicesByName([string[]]$names) {
    $detenidos = @()
    foreach ($svcName in $names) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and (Test-InList $svcName $Config.serviciosServidores)) {
            Write-Log "Blindado (server): el servicio $svcName no se pausa." 'warn'
            continue
        }
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                $detenidos += $svcName
                Write-Log "Servicio pausado: $($svc.DisplayName)" 'ok'
            } catch {
                Write-Log "No se pudo pausar el servicio $svcName" 'err'
            }
        }
    }
    if ($detenidos.Count -gt 0) { Add-StoppedToState $detenidos }
    return $detenidos.Count
}

function Restore-Services {
    $state = Get-State
    $lista = @($Config.serviciosPausables) + @($state.servicios)
    foreach ($svcName in ($lista | Select-Object -Unique)) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                Write-Log "Servicio restaurado: $($svc.DisplayName)" 'ok'
            } catch {
                Write-Log "No se pudo iniciar el servicio $svcName" 'err'
            }
        }
    }
    if ($state.planEnergiaPrevio) {
        powercfg /setactive $state.planEnergiaPrevio 2>&1 | Out-Null
        Write-Log 'Plan de energía original restaurado.' 'ok'
    }
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
    Refresh-ServiceList
}

# --- Módulo de red: bajar latencia -----------------------------
$script:SPKeyPS  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:SPKeyReg = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:IfRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'

function Get-RegValueOrNull($path, $name) {
    $p = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties.Name -contains $name) { return $p.$name }
    return $null
}

function Optimize-Network {
    if (Test-Path $NetBackupPath) {
        Write-Log "La optimización de red ya estaba aplicada (usá 'Revertir red' para deshacerla)." 'warn'
        return
    }
    $backup = [ordered]@{ systemProfile = [ordered]@{}; interfaces = [ordered]@{} }

    # 1) Desactivar el throttling de red que Windows aplica cuando hay multimedia.
    #    Si un valor ya está igual o mejor (otro tweak previo), no se toca.
    $nti = Get-RegValueOrNull $SPKeyPS 'NetworkThrottlingIndex'
    $sr  = Get-RegValueOrNull $SPKeyPS 'SystemResponsiveness'
    $backup.systemProfile.NetworkThrottlingIndex = $nti
    $backup.systemProfile.SystemResponsiveness   = $sr
    if ($nti -eq 4294967295) {
        Write-Log 'Throttling de red ya estaba desactivado, no se toca.' 'info'
    } else {
        reg.exe add $SPKeyReg /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f | Out-Null
        Write-Log 'Throttling de red de Windows desactivado.' 'ok'
    }
    if ($null -ne $sr -and $sr -le 10) {
        Write-Log "SystemResponsiveness ya estaba en $sr (igual o mejor), no se toca." 'info'
    } else {
        reg.exe add $SPKeyReg /v SystemResponsiveness /t REG_DWORD /d 10 /f | Out-Null
        Write-Log 'Prioridad multimedia ajustada (SystemResponsiveness = 10).' 'ok'
    }

    # 2) Desactivar algoritmo de Nagle y delayed ACK en las interfaces con IP
    #    (Nagle agrupa paquetes chicos antes de mandarlos: bueno para descargas,
    #     malo para el ping en juegos)
    $n = 0
    foreach ($iface in (Get-ChildItem $IfRoot)) {
        $props = Get-ItemProperty $iface.PSPath
        $tieneIp = ($props.PSObject.Properties.Name -contains 'DhcpIPAddress' -and $props.DhcpIPAddress) -or
                   ($props.PSObject.Properties.Name -contains 'IPAddress' -and $props.IPAddress -and $props.IPAddress[0])
        if (-not $tieneIp) { continue }
        $backup.interfaces[$iface.PSChildName] = [ordered]@{
            TcpAckFrequency = Get-RegValueOrNull $iface.PSPath 'TcpAckFrequency'
            TCPNoDelay      = Get-RegValueOrNull $iface.PSPath 'TCPNoDelay'
        }
        Set-ItemProperty -Path $iface.PSPath -Name TcpAckFrequency -Value 1 -Type DWord
        Set-ItemProperty -Path $iface.PSPath -Name TCPNoDelay -Value 1 -Type DWord
        $n++
    }
    Write-Log "Nagle/delayed ACK desactivados en $n interfaz(es) de red." 'ok'

    ConvertTo-Json -InputObject $backup -Depth 5 | Set-Content $NetBackupPath -Encoding UTF8

    # 3) Limpiar caché DNS
    ipconfig /flushdns | Out-Null
    Write-Log 'Caché DNS limpiada.' 'ok'
    Write-Log 'Los cambios de registro terminan de aplicarse al reiniciar la PC.' 'info'
}

function Restore-Network {
    if (-not (Test-Path $NetBackupPath)) {
        Write-Log 'No hay optimización de red aplicada para revertir.' 'warn'
        return
    }
    $backup = Get-Content $NetBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in 'NetworkThrottlingIndex','SystemResponsiveness') {
        $val = $backup.systemProfile.$name
        if ($null -eq $val) {
            Remove-ItemProperty -Path $SPKeyPS -Name $name -ErrorAction SilentlyContinue
        } else {
            reg.exe add $SPKeyReg /v $name /t REG_DWORD /d ([uint32]$val) /f | Out-Null
        }
    }
    foreach ($ifName in $backup.interfaces.PSObject.Properties.Name) {
        $ifPath = Join-Path $IfRoot $ifName
        if (-not (Test-Path $ifPath)) { continue }
        $vals = $backup.interfaces.$ifName
        foreach ($name in 'TcpAckFrequency','TCPNoDelay') {
            if ($null -eq $vals.$name) {
                Remove-ItemProperty -Path $ifPath -Name $name -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $ifPath -Name $name -Value ([int]$vals.$name) -Type DWord
            }
        }
    }
    Remove-Item $NetBackupPath -Force
    Write-Log 'Configuración de red revertida a los valores originales (se completa al reiniciar).' 'ok'
}

# --- Tweaks persistentes: GameDVR y ahorro de energía ----------
$script:GameDvrKeys = @(
    @{ PS = 'HKCU:\System\GameConfigStore';                            Name = 'GameDVR_Enabled' },
    @{ PS = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' },
    @{ PS = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';       Name = 'AllowGameDVR' }
)

function Disable-DevicePowerSaving {
    # Desactiva "permitir que el equipo apague este dispositivo" en la
    # placa de red activa y en los dispositivos USB (evita picos de
    # latencia y bajones de polling del mouse). Devuelve lo que tocó.
    $apagados = @()
    $nicIds = @()
    try {
        $nicIds = @((Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }).PnpDeviceID)
    } catch {}
    foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)) {
        if (-not $d.Enable) { continue }
        $esNic = $false
        foreach ($id in $nicIds) {
            if ($id -and $d.InstanceName -like "$id*") { $esNic = $true; break }
        }
        if (-not ($esNic -or $d.InstanceName -like 'USB\*')) { continue }
        try {
            Set-CimInstance -InputObject $d -Property @{ Enable = $false } -ErrorAction Stop
            $apagados += $d.InstanceName
        } catch {}
    }
    return ,$apagados
}

function Optimize-System {
    # Aplica todos los tweaks persistentes. Cada bloque guarda backup
    # y se saltea si Booster ya lo aplicó antes.
    Optimize-Network

    $tweaks = $null
    if (Test-Path $TweaksPath) {
        try { $tweaks = Get-Content $TweaksPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if (-not $tweaks) { $tweaks = [pscustomobject]@{} }

    # GameDVR / Game Bar: Windows graba gameplay de fondo por defecto
    if ($tweaks.PSObject.Properties.Name -notcontains 'gameDvr') {
        $bk = [ordered]@{}
        foreach ($k in $GameDvrKeys) {
            $bk[$k.Name] = Get-RegValueOrNull $k.PS $k.Name
            if (-not (Test-Path $k.PS)) { New-Item -Path $k.PS -Force | Out-Null }
            Set-ItemProperty -Path $k.PS -Name $k.Name -Value 0 -Type DWord
        }
        $tweaks | Add-Member -NotePropertyName gameDvr -NotePropertyValue $bk
        Write-Log 'GameDVR / Game Bar desactivados: la GPU deja de grabar gameplay de fondo.' 'ok'
    } else {
        Write-Log 'GameDVR ya estaba desactivado por Booster.' 'info'
    }

    # Ahorro de energía de NIC y USB
    $aplicarAhorro = $true
    if ($tweaks.PSObject.Properties.Name -notcontains 'ahorroDispositivos' -and (Get-Alimentacion) -ne 'escritorio') {
        # Notebook: este tweak cuesta batería, así que se pregunta
        $resp = [System.Windows.Forms.MessageBox]::Show("Esta PC tiene batería.`n`nApagar el ahorro de energía de la placa de red y los puertos USB baja la latencia, pero gasta más batería cuando estás desenchufado.`n`n¿Aplicarlo igual?", 'Booster - Notebook', 'YesNo', 'Question')
        $aplicarAhorro = ($resp -eq 'Yes')
    }
    if (-not $aplicarAhorro) {
        Write-Log "Ahorro de energía de red/USB: lo dejé como estaba (notebook). Podés aplicarlo después tocando 'Optimizar PC' de nuevo." 'info'
    } elseif ($tweaks.PSObject.Properties.Name -notcontains 'ahorroDispositivos') {
        $apagados = Disable-DevicePowerSaving
        $tweaks | Add-Member -NotePropertyName ahorroDispositivos -NotePropertyValue $apagados
        Write-Log ("Ahorro de energía desactivado en {0} dispositivo(s) de red/USB." -f @($apagados).Count) 'ok'
    } else {
        Write-Log 'El ahorro de energía de red/USB ya estaba desactivado por Booster.' 'info'
    }

    ConvertTo-Json -InputObject $tweaks -Depth 6 | Set-Content $TweaksPath -Encoding UTF8
}

function Restore-Tweaks {
    Restore-Network

    $tweaks = $null
    if (Test-Path $TweaksPath) {
        try { $tweaks = Get-Content $TweaksPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if (-not $tweaks) { return }

    if ($tweaks.PSObject.Properties.Name -contains 'gameDvr') {
        foreach ($k in $GameDvrKeys) {
            $val = $tweaks.gameDvr.($k.Name)
            if ($null -eq $val) {
                Remove-ItemProperty -Path $k.PS -Name $k.Name -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $k.PS -Name $k.Name -Value ([int]$val) -Type DWord
            }
        }
        Write-Log 'GameDVR restaurado a su configuración original.' 'ok'
    }

    if ($tweaks.PSObject.Properties.Name -contains 'timerGlobal') {
        $val = $tweaks.timerGlobal.previo
        if ($null -eq $val) {
            Remove-ItemProperty -Path $TimerGlobalKey -Name 'GlobalTimerResolutionRequests' -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $TimerGlobalKey -Name 'GlobalTimerResolutionRequests' -Value ([int]$val) -Type DWord
        }
        Write-Log 'Timer global restaurado a su valor original (se completa al reiniciar).' 'ok'
    }

    if ($tweaks.PSObject.Properties.Name -contains 'ahorroDispositivos') {
        $instancias = @($tweaks.ahorroDispositivos)
        $n = 0
        foreach ($d in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)) {
            if ($instancias -contains $d.InstanceName) {
                try {
                    Set-CimInstance -InputObject $d -Property @{ Enable = $true } -ErrorAction Stop
                    $n++
                } catch {}
            }
        }
        Write-Log "Ahorro de energía reactivado en $n dispositivo(s)." 'ok'
    }
    Remove-Item $TweaksPath -Force
}

# --- Plan de energía y timer de alta precisión ------------------
$script:PlanAltoRendimiento = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

function Get-ActivePowerPlan {
    $out = powercfg /getactivescheme 2>&1 | Out-String
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    return $null
}

function Get-Alimentacion {
    # 'escritorio' (sin batería), 'enchufada' o 'bateria'
    try {
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ([int]$ps.BatteryChargeStatus -band [int][System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) { return 'escritorio' }
        if ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) { return 'bateria' }
        return 'enchufada'
    } catch { return 'escritorio' }
}

function Enable-HighPerformance {
    if ((Get-Alimentacion) -eq 'bateria') {
        Write-Log 'Estás a batería: no cambio el plan de energía (Alto rendimiento la consume rápido). Enchufá el cargador para rendir al máximo.' 'warn'
        return
    }
    $actual = Get-ActivePowerPlan
    if (-not $actual) { return }
    # Solo se cambia si el plan actual es uno de los stock que frenan el CPU
    # (Equilibrado o Economizador). Un plan de rendimiento ya activo
    # (Alto, Ultimate, o uno custom tipo ExitLag) no se toca.
    $planesLentos = @('381b4222-f694-41f0-9685-ff5bb260df2e', 'a1841308-3541-4fab-bc81-f71556f20b4a')
    if ($planesLentos -notcontains $actual.ToLower()) {
        Write-Log 'Tu plan de energía actual ya es de rendimiento, no se toca.' 'info'
        return
    }
    powercfg /setactive $PlanAltoRendimiento 2>&1 | Out-Null
    $nuevo = Get-ActivePowerPlan
    if ($nuevo -ine $PlanAltoRendimiento) {
        # En algunas PCs el plan viene oculto: se duplica y se activa la copia
        $dup = powercfg /duplicatescheme $PlanAltoRendimiento 2>&1 | Out-String
        if ($dup -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            powercfg /setactive $Matches[1] 2>&1 | Out-Null
            $nuevo = Get-ActivePowerPlan
        }
    }
    if ($nuevo -ine $actual) {
        $state = Get-State
        $state.planEnergiaPrevio = $actual
        Save-State $state
        Write-Log "Plan de energía: Alto rendimiento activado (se vuelve con 'Restaurar todo')." 'ok'
    } else {
        Write-Log 'No se pudo activar el plan Alto rendimiento.' 'err'
    }
}

# --- Timer de 0,5 ms (opcional) ---------------------------------
# Medido en Windows 10 22H2: con OTRO proceso pidiendo 0,5 ms, un Sleep(1)
# sigue tardando ~15 ms en el que no lo pidió. O sea: en Windows 10 (2004+)
# esto no le llega al juego. En Windows 11 sí, pero solo con la clave
# GlobalTimerResolutionRequests (botón 'Timer global' de la página Pro).
$script:TimerGlobalKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'
$script:EsWin11 = ([Environment]::OSVersion.Version.Build -ge 22000)

function Test-TimerGlobal {
    return ($script:EsWin11 -and ((Get-RegValueOrNull $TimerGlobalKey 'GlobalTimerResolutionRequests') -eq 1))
}

function Set-TimerResolution([bool]$activar) {
    $min = [uint32]0; $max = [uint32]0; $cur = [uint32]0
    [void][BoosterTimer]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur)
    $out = [uint32]0
    if (-not $activar) {
        [void][BoosterTimer]::NtSetTimerResolution($max, $false, [ref]$out)
        Write-Log 'Timer del sistema liberado.' 'info'
        return
    }
    [void][BoosterTimer]::NtSetTimerResolution($max, $true, [ref]$out)
    [void][BoosterTimer]::KeepWhenHidden()
    Write-Log ("Timer pedido: {0:N2} ms -> {1:N2} ms (dura mientras Booster esté abierto)." -f ($cur / 10000), ($out / 10000)) 'ok'
    if (Test-TimerGlobal) {
        Write-Log 'Clave global activa: el timer le llega a todos los procesos, incluido el juego.' 'ok'
    } elseif ($script:EsWin11) {
        Write-Log "Ojo: en Windows 11 el timer es por proceso. Para que le llegue al juego, tocá 'Timer global' en la página Pro y reiniciá." 'warn'
    } else {
        Write-Log 'Ojo: en Windows 10 (2004 en adelante) el timer es por proceso y no le llega al juego. Queda prendido, pero no esperes diferencia.' 'warn'
    }
}

function Enable-TimerGlobal {
    # Windows 11: vuelve global el pedido de timer (como era antes de 2004).
    # Tweak persistente de registro, con backup en el mismo archivo que el resto.
    if (-not $script:EsWin11) {
        Write-Log 'El timer global solo existe en Windows 11. En Windows 10 no hay forma de que el timer de Booster le llegue al juego.' 'warn'
        return
    }
    $tweaks = $null
    if (Test-Path $TweaksPath) {
        try { $tweaks = Get-Content $TweaksPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if (-not $tweaks) { $tweaks = [pscustomobject]@{} }
    if ($tweaks.PSObject.Properties.Name -contains 'timerGlobal') {
        Write-Log "El timer global ya estaba activado por Booster ('Revertir tweaks' lo deshace)." 'info'
        return
    }
    $previo = Get-RegValueOrNull $TimerGlobalKey 'GlobalTimerResolutionRequests'
    try {
        Set-ItemProperty -Path $TimerGlobalKey -Name 'GlobalTimerResolutionRequests' -Value 1 -Type DWord -ErrorAction Stop
    } catch {
        Write-Log "No se pudo escribir la clave del timer global: $($_.Exception.Message)" 'err'
        return
    }
    $tweaks | Add-Member -NotePropertyName timerGlobal -NotePropertyValue ([pscustomobject]@{ previo = $previo })
    ConvertTo-Json -InputObject $tweaks -Depth 6 | Set-Content $TweaksPath -Encoding UTF8
    Write-Log "Timer global activado. REINICIÁ la PC para que tome efecto; después prendé el toggle 'Timer 0,5 ms'." 'ok'
}

# --- Afinidad a núcleos P (CPUs híbridas) -----------------------
$script:CpuTopo    = [BoosterCpu]::Query()      # [mascaraP, mascaraTodos, nucleosP, nucleosE]
$script:CpuHibrido = ($script:CpuTopo[0] -ne 0)

function Get-GameProcesses {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-InList $_.Name $Config.juegos })
}

function Set-GameAffinity($proc, [bool]$soloP) {
    # Fija el juego a los núcleos P (o lo devuelve a todos). Muere con el
    # proceso del juego: no deja nada cambiado en Windows.
    if (-not $script:CpuHibrido) { return }
    $mask = if ($soloP) { $script:CpuTopo[0] } else { $script:CpuTopo[1] }
    try {
        if ([long]$proc.ProcessorAffinity -eq $mask) { return }
        $proc.ProcessorAffinity = [IntPtr]$mask
        if ($soloP) {
            Write-Log "Solo P-cores: $($proc.Name) fijado a los $($script:CpuTopo[2]) núcleos de rendimiento." 'ok'
        } else {
            Write-Log "$($proc.Name) vuelve a usar todos los núcleos." 'info'
        }
    } catch {
        Write-Log "No se pudo cambiar la afinidad de $($proc.Name) (algunos anticheat lo bloquean, no pasa nada)." 'warn'
    }
}

function Test-QuierePCores([string]$nombreJuego) {
    if ($chkPCores.Checked) { return $true }
    $perfil = @($Config.perfiles) | Where-Object { $_ -and $nombreJuego -like $_.juego } | Select-Object -First 1
    return [bool]($perfil -and $perfil.PSObject.Properties.Name -contains 'soloPCores' -and $perfil.soloPCores)
}

# --- Purga de memoria standby (estilo ISLC) --------------------
function Get-StandbyMB {
    try {
        $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        return [Math]::Round(($m.StandbyCacheCoreBytes + $m.StandbyCacheNormalPriorityBytes + $m.StandbyCacheReserveBytes) / 1MB)
    } catch { return $null }
}

function Clear-StandbyMemory {
    # La lista standby es RAM "cacheada" que Windows guarda por las dudas.
    # Cuando se llena, algunos juegos stutterean; purgarla la devuelve como libre.
    $antes = Get-StandbyMB
    $libreAntes = Get-FreeRamMB
    $r = [BoosterMem]::PurgeStandbyList()
    if ($r -ne 0) {
        Write-Log ("No se pudo purgar la memoria standby (código 0x{0:X8})." -f $r) 'err'
        return
    }
    Start-Sleep -Milliseconds 500
    $libreDespues = Get-FreeRamMB
    $liberado = [Math]::Max(0, $libreDespues - $libreAntes)
    # Marca para el gráfico en vivo: línea verde en el momento exacto
    # de la purga con los GB liberados
    $script:PurgadoSesionMB += $liberado
    if ($null -ne $script:PurgeMarks) {
        [void]$script:PurgeMarks.Add(@{ Tick = $script:TickNum; Texto = ('-{0:N1} GB' -f ($liberado / 1024)) })
        if ($script:PurgeMarks.Count -gt 50) { $script:PurgeMarks.RemoveAt(0) }
    }
    if ($null -ne $antes) {
        Write-Log ("Memoria standby purgada: {0:N0} MB -> {1:N0} MB." -f $antes, (Get-StandbyMB)) 'ok'
    } else {
        # En algunas PCs los contadores de standby no están disponibles:
        # se informa con la RAM libre, que igual refleja el efecto
        Write-Log ("Memoria standby purgada (RAM libre: {0:N0} MB -> {1:N0} MB)." -f $libreAntes, $libreDespues) 'ok'
    }
}

# --- Gestor de apps de inicio -----------------------------------
# Usa las claves StartupApproved, la misma mecánica que el botón
# habilitar/deshabilitar del Administrador de tareas: no borra nada,
# y los cambios se ven y se pueden deshacer desde ahí también.
$script:StartupSources = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Origen = 'Usuario' },
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';   Origen = 'Sistema' },
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Origen = 'Sistema (32b)' }
)

function Get-StartupEnabled($approvedKey, $name) {
    $val = Get-RegValueOrNull $approvedKey $name
    if ($null -eq $val -or $val.Length -eq 0) { return $true }
    return (($val[0] % 2) -eq 0)   # primer byte par = habilitado, impar = deshabilitado
}

function Set-StartupEnabled($approvedKey, $name, [bool]$habilitar) {
    if (-not (Test-Path $approvedKey)) { New-Item -Path $approvedKey -Force | Out-Null }
    $bytes = [byte[]]::new(12)
    $bytes[0] = $(if ($habilitar) { 2 } else { 3 })
    Set-ItemProperty -Path $approvedKey -Name $name -Value $bytes -Type Binary
}

function Get-StartupItems {
    $items = @()
    foreach ($src in $StartupSources) {
        if (-not (Test-Path $src.Run)) { continue }
        $p = Get-ItemProperty $src.Run
        foreach ($prop in $p.PSObject.Properties) {
            if (@('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') -contains $prop.Name) { continue }
            $items += [pscustomobject]@{
                Nombre     = $prop.Name
                Comando    = [string]$prop.Value
                Origen     = $src.Origen
                Approved   = $src.Approved
                Habilitado = Get-StartupEnabled $src.Approved $prop.Name
            }
        }
    }
    $carpetas = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Origen = 'Carpeta Inicio' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Origen = 'Carpeta común' }
    )
    foreach ($c in $carpetas) {
        if (-not $c.Path -or -not (Test-Path $c.Path)) { continue }
        foreach ($f in (Get-ChildItem $c.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $items += [pscustomobject]@{
                Nombre     = $f.Name
                Comando    = $f.FullName
                Origen     = $c.Origen
                Approved   = $c.Approved
                Habilitado = Get-StartupEnabled $c.Approved $f.Name
            }
        }
    }
    $items | Sort-Object Nombre
}

function Show-StartupManager {
    $items = @(Get-StartupItems)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Booster - Apps de inicio'
    $dlg.Size            = New-Object System.Drawing.Size(760, 540)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colBg
    $dlg.ForeColor       = $colText

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Esto es lo que arranca junto con Windows. Destildá lo que no necesites`ny tocá Aplicar (mismo efecto que en el Administrador de tareas, reversible)."
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size     = New-Object System.Drawing.Size(715, 36)
    $dlg.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(15, 55)
    $lv.Size          = New-Object System.Drawing.Size(715, 380)
    $lv.View          = 'Details'
    $lv.CheckBoxes    = $true
    $lv.FullRowSelect = $true
    $lv.BackColor     = $colPanel
    $lv.ForeColor     = $colText
    $lv.BorderStyle   = 'FixedSingle'
    [void]$lv.Columns.Add('Nombre', 210)
    [void]$lv.Columns.Add('Origen', 95)
    [void]$lv.Columns.Add('Comando', 385)
    foreach ($it in $items) {
        $item = New-Object System.Windows.Forms.ListViewItem($it.Nombre)
        [void]$item.SubItems.Add($it.Origen)
        [void]$item.SubItems.Add($it.Comando)
        $item.Checked = $it.Habilitado
        $item.Tag     = $it
        if (-not $it.Habilitado) { $item.ForeColor = $colDim }
        [void]$lv.Items.Add($item)
    }
    $dlg.Controls.Add($lv)

    $btnAplicar = New-Object System.Windows.Forms.Button
    $btnAplicar.Text         = 'Aplicar cambios'
    $btnAplicar.Location     = New-Object System.Drawing.Point(15, 450)
    $btnAplicar.Size         = New-Object System.Drawing.Size(220, 36)
    $btnAplicar.BackColor    = $colAccent
    $btnAplicar.ForeColor    = $colDark
    $btnAplicar.FlatStyle    = 'Flat'
    $btnAplicar.DialogResult = 'OK'
    $dlg.Controls.Add($btnAplicar)

    $btnCerrar = New-Object System.Windows.Forms.Button
    $btnCerrar.Text         = 'Cancelar'
    $btnCerrar.Location     = New-Object System.Drawing.Point(510, 450)
    $btnCerrar.Size         = New-Object System.Drawing.Size(220, 36)
    $btnCerrar.BackColor    = $colPanel
    $btnCerrar.ForeColor    = $colText
    $btnCerrar.FlatStyle    = 'Flat'
    $btnCerrar.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCerrar)

    Invoke-UiScale $dlg
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $cambios = 0
    foreach ($item in $lv.Items) {
        $it = $item.Tag
        if ($item.Checked -eq $it.Habilitado) { continue }
        try {
            Set-StartupEnabled $it.Approved $it.Nombre $item.Checked
            $accion = if ($item.Checked) { 'habilitado' } else { 'deshabilitado' }
            Write-Log "Inicio ${accion}: $($it.Nombre)" 'ok'
            $cambios++
        } catch {
            Write-Log "No se pudo cambiar el inicio de $($it.Nombre)" 'err'
        }
    }
    if ($cambios -eq 0) { Write-Log 'Apps de inicio: sin cambios.' 'info' }
    else { Write-Log "Apps de inicio: $cambios cambio(s). Aplica en el próximo arranque de Windows." 'info' }
}

function Test-PingLatency {
    $form.Cursor = 'WaitCursor'
    Write-Log 'Midiendo latencia, dame unos segundos...' 'title'
    foreach ($target in @('1.1.1.1', '8.8.8.8')) {
        $res = Test-Connection -ComputerName $target -Count 6 -ErrorAction SilentlyContinue
        if (-not $res) {
            Write-Log "${target}: sin respuesta" 'err'
            continue
        }
        $times = @($res | ForEach-Object { $_.ResponseTime })
        $avg = [Math]::Round(($times | Measure-Object -Average).Average, 1)
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $jitter = 0.0
        for ($i = 1; $i -lt $times.Count; $i++) { $jitter += [Math]::Abs($times[$i] - $times[$i - 1]) }
        if ($times.Count -gt 1) { $jitter = [Math]::Round($jitter / ($times.Count - 1), 1) }
        Write-Log ("{0}: {1} ms promedio (min {2} / max {3}), jitter {4} ms" -f $target, $avg, $min, $max, $jitter) 'ok'
    }
    $form.Cursor = 'Default'
}

function Show-KillPicker($items) {
    # Dialogo del "modo mixto": apps abiertas + procesos de fondo
    # detectados. Devuelve los nombres tildados.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Booster - Confirmar cierre'
    $dlg.Size            = New-Object System.Drawing.Size(500, 520)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colBg
    $dlg.ForeColor       = $colText

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Tus apps vienen tildadas; lo de 'Fondo' viene destildado: tildá solo`nlo que quieras cerrar. Los servers blindados ni aparecen."
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size     = New-Object System.Drawing.Size(455, 36)
    $dlg.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(15, 55)
    $lv.Size          = New-Object System.Drawing.Size(455, 360)
    $lv.View          = 'Details'
    $lv.CheckBoxes    = $true
    $lv.FullRowSelect = $true
    $lv.BackColor     = $colPanel
    $lv.ForeColor     = $colText
    $lv.BorderStyle   = 'FixedSingle'
    [void]$lv.Columns.Add('Proceso', 230)
    [void]$lv.Columns.Add('RAM (MB)', 100)
    [void]$lv.Columns.Add('Tipo', 100)
    foreach ($it in $items) {
        $item = New-Object System.Windows.Forms.ListViewItem($it.Name)
        [void]$item.SubItems.Add([string]$it.RamMB)
        [void]$item.SubItems.Add($it.Tipo)
        # Las apps de tu lista vienen tildadas; lo que encontró el barrido
        # de fondo viene DESTILDADO: se cierra solo si lo elegís vos.
        $item.Checked = ($it.Tipo -ne 'Fondo')
        if ($it.Tipo -eq 'Fondo') { $item.ForeColor = $colDim }
        [void]$lv.Items.Add($item)
    }
    $dlg.Controls.Add($lv)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text         = 'Cerrar tildados'
    $btnOk.Location     = New-Object System.Drawing.Point(15, 430)
    $btnOk.Size         = New-Object System.Drawing.Size(220, 36)
    $btnOk.BackColor    = $colAccent
    $btnOk.ForeColor    = $colDark
    $btnOk.FlatStyle    = 'Flat'
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'No cerrar ninguno'
    $btnCancel.Location     = New-Object System.Drawing.Point(250, 430)
    $btnCancel.Size         = New-Object System.Drawing.Size(220, 36)
    $btnCancel.BackColor    = $colPanel
    $btnCancel.ForeColor    = $colText
    $btnCancel.FlatStyle    = 'Flat'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    Invoke-UiScale $dlg
    if ($dlg.ShowDialog($form) -eq 'OK') {
        return @($lv.CheckedItems | ForEach-Object { $_.Text })
    }
    return @()
}

function Set-GamePriority {
    # Prioridad de CPU ALTA para los juegos corriendo: lo mismo que harías
    # a mano en el Administrador de tareas. Muere con el proceso del juego.
    foreach ($p in (Get-GameProcesses)) {
        try {
            if ($p.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::High) {
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                Write-Log "Prioridad de CPU ALTA para $($p.Name) (PID $($p.Id))." 'ok'
            }
        } catch {
            Write-Log "No se pudo subir la prioridad de $($p.Name) (algunos anticheat lo bloquean, no pasa nada)." 'warn'
        }
        if (Test-QuierePCores $p.Name) { Set-GameAffinity $p $true }
    }
}

function Clear-Junk {
    # Temporales de Windows y cachés de shaders viejos. Los shaders se
    # recompilan solos la próxima vez que abras el juego (esa primera
    # carga puede tardar un poco más); lo que está en uso se saltea solo.
    Write-Log '=== LIMPIEZA DE BASURA ===' 'title'
    $objetivos = @(
        $env:TEMP,
        (Join-Path $env:WINDIR 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache')
    )
    $totalMB = 0
    foreach ($dir in $objetivos) {
        if (-not (Test-Path $dir)) { continue }
        $antes = (Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Get-ChildItem $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        $despues = (Get-ChildItem $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $lib = [Math]::Max(0, ($antes - $despues)) / 1MB
        $totalMB += $lib
        Write-Log ("{0}: {1:N0} MB liberados" -f $dir, $lib) 'ok'
    }
    Write-Log ("Basura liberada: {0:N0} MB en total." -f $totalMB) 'title'
}

function Invoke-WorkMode {
    # El botón inverso: restaura todo y te reabre las apps de trabajo
    Write-Log '=== MODO TRABAJO ===' 'title'
    Restore-Services
    if ($chkTimer.Checked) { $chkTimer.Checked = $false }
    if ($chkAuto.Checked)  { $chkAuto.Checked  = $false }
    $lista = @($Config.abrirEnTrabajo | Where-Object { $_ })
    if ($lista.Count -eq 0) {
        Write-Log "Tip: poné rutas o nombres de tus apps de trabajo en 'abrirEnTrabajo' del config.json y este botón te las abre solas." 'info'
    }
    foreach ($app in $lista) {
        try {
            Start-Process $app
            Write-Log "Abierto: $app" 'ok'
        } catch {
            Write-Log "No se pudo abrir: $app" 'err'
        }
    }
    Write-Log 'De vuelta al laburo. Éxitos.' 'title'
}

function Invoke-GamingMode([switch]$Silencioso, [string[]]$Conservar = @()) {
    $script:BoostEnCurso = $true
    Write-Log $(if ($Silencioso) { '=== MODO GAMING AUTOMÁTICO (silencioso) ===' } else { '=== MODO GAMING ACTIVADO ===' }) 'title'
    $ramAntes = Get-FreeRamMB

    # 1) Cierre automático de la lista segura (con comodines).
    #    El perfil del juego puede pedir conservar algunas apps.
    $auto = @(Get-RunningMatches $Config.cerrarSiempre)
    $aCerrar = @()
    foreach ($g in $auto) {
        if (Test-InList $g.Name $Conservar) {
            Write-Log "Conservado por perfil del juego: $($g.Name)" 'info'
            continue
        }
        $aCerrar += $g.Name
    }
    Close-ProcessesByName $aCerrar
    if ($auto.Count -eq 0) { Write-Log 'Nada que cerrar de la lista automática.' 'info' }

    # 2) Modo mixto: apps conocidas + barrido de procesos de fondo.
    #    En modo silencioso (auto-gaming) no se muestra el diálogo para
    #    no interrumpir el juego: solo se cierra la lista automática.
    if (-not $Silencioso) {
        $ask   = @(Get-RunningMatches $Config.preguntarAntes | ForEach-Object { $_ | Add-Member Tipo 'App' -PassThru })
        $fondo = @(Get-BackgroundApps | ForEach-Object { $_ | Add-Member Tipo 'Fondo' -PassThru })
        $items = @($ask + $fondo | Sort-Object RamMB -Descending)
        if ($items.Count -gt 0) {
            $elegidos = Show-KillPicker $items
            Close-ProcessesByName @($elegidos)
        }
    }

    # 3) Servicios pesados de Windows
    $n = Stop-ServicesByName @($Config.serviciosPausables)

    # 4) Servicios de terceros (updaters, Adobe, etc.)
    $svcTerceros = @(Get-ThirdPartyServices | Where-Object {
        (Test-InList $_.Name $Config.serviciosTercerosAuto) -or
        (Test-InList $_.DisplayName $Config.serviciosTercerosAuto)
    })
    if ($svcTerceros.Count -gt 0) {
        $n += Stop-ServicesByName @($svcTerceros | ForEach-Object { $_.Name })
    }
    if ($n -eq 0) { Write-Log 'No había servicios pausables corriendo.' 'info' }

    # 5) Red: limpiar caché DNS y recordar los tweaks persistentes
    ipconfig /flushdns | Out-Null
    Write-Log 'Caché DNS limpiada.' 'ok'
    if (-not (Test-Path $NetBackupPath) -or -not (Test-Path $TweaksPath)) {
        Write-Log "Tip: tocá 'Optimizar PC' para los tweaks persistentes (red, GameDVR, ahorro de energía). Se hace una sola vez." 'info'
    }

    # 6) Plan de energía Alto rendimiento
    Enable-HighPerformance

    # 7) Purgar la memoria standby (los procesos recién cerrados dejan caché)
    Start-Sleep -Milliseconds 1500
    Clear-StandbyMemory

    # 8) Si ya hay un juego corriendo: prioridad de CPU alta y, si está
    #    pedido (toggle o perfil), afinidad a los núcleos P
    Set-GamePriority

    $ramDespues = Get-FreeRamMB
    $ganancia = $ramDespues - $ramAntes
    Write-Log ("=== LISTO. RAM libre: {0:N0} MB -> {1:N0} MB ({2}{3:N0} MB) ===" -f $ramAntes, $ramDespues, $(if ($ganancia -ge 0) { '+' } else { '' }), $ganancia) 'title'

    Refresh-ServiceList
    Refresh-ProcessList
    $script:BoostEnCurso = $false
}

# --- GUI v8: 3 páginas (Limpieza / Recursos / Pro) + bandeja -----
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Booster - Optimizador gaming'
$form.Size            = New-Object System.Drawing.Size(1180, 850)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $colBg
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.5)

# --- Motor visual ----------------------------------------------------
# Todo lo redondeado se PINTA con antialiasing (antes se recortaba con
# Region y los bordes quedaban serruchados). Los botones tienen estado
# hover/presionado y los toggles son interruptores de verdad.
$script:sfCenter = New-Object System.Drawing.StringFormat
$script:sfCenter.Alignment     = 'Center'
$script:sfCenter.LineAlignment = 'Center'
$script:sfLeft = New-Object System.Drawing.StringFormat
$script:sfLeft.LineAlignment = 'Center'
$script:sfLeft.FormatFlags   = 'NoWrap'
$script:sfLeft.Trimming      = 'EllipsisCharacter'
$script:uiFontHead = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$script:uiBrHead   = New-Object System.Drawing.SolidBrush($colBg)
$script:uiBrDim    = New-Object System.Drawing.SolidBrush($colDim)
$script:uiPenLine  = New-Object System.Drawing.Pen($colSurface, 1)

# --- Escala de la interfaz ---
# Px    = factor de tamaño (DPI de Windows x ajuste a la pantalla x 'escalaUI')
# FontK = factor de fuentes (el DPI no entra: Windows ya agranda los puntos solo)
$script:Px    = 1.0
$script:FontK = 1.0

function Initialize-UiScale {
    $dpi = 96.0
    try { $g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpi = $g0.DpiX; $g0.Dispose() } catch {}
    $s = $dpi / 96.0
    $user = 1.0
    try { if ([double]$Config.escalaUI -gt 0) { $user = [Math]::Min(2.5, [Math]::Max(0.6, [double]$Config.escalaUI)) } } catch {}
    # Si la ventana no entra en la pantalla (notebooks de 1366x768), se achica entera
    $wa  = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $fit = [Math]::Min(1.0, [Math]::Min(($wa.Width - 8) / ($form.Width * $s * $user), ($wa.Height - 8) / ($form.Height * $s * $user)))
    $fit = [Math]::Max(0.6, $fit)
    $script:FontK = $fit * $user
    $script:Px    = $s * $script:FontK
    if ([Math]::Abs($script:Px - 1) -ge 0.01) {
        $script:RowImgs.ImageSize = New-Object System.Drawing.Size(1, [int](26 * $script:Px))
    }
    if ([Math]::Abs($script:FontK - 1) -ge 0.01) {
        $script:uiFontHead = New-Object System.Drawing.Font('Segoe UI Semibold', [single](8 * $script:FontK))
    }
}

function Get-AllControls($root) {
    foreach ($c in $root.Controls) { $c; Get-AllControls $c }
}

function Invoke-UiScale($root) {
    # Lleva una ventana ya armada (coordenadas pensadas a 96 dpi) a la escala real
    $hayPx   = [Math]::Abs($script:Px - 1) -ge 0.01
    $hayFont = [Math]::Abs($script:FontK - 1) -ge 0.01
    if (-not $hayPx -and -not $hayFont) { return }
    if ($root -is [System.Windows.Forms.Form]) { $root.AutoScaleMode = 'None' }
    $todos = @($root) + @(Get-AllControls $root)
    # Foto de fuentes y columnas ANTES de tocar nada (las fuentes se heredan
    # del padre: si se escalan en cadena, se escalan dos veces)
    $fuentes = @{}; $columnas = @{}
    foreach ($c in $todos) {
        $fuentes[$c] = $c.Font
        if ($c -is [System.Windows.Forms.ListView]) { $columnas[$c] = @($c.Columns | ForEach-Object { $_.Width }) }
    }
    if ($hayPx) { $root.Scale((New-Object System.Drawing.SizeF([single]$script:Px, [single]$script:Px))) }
    foreach ($c in $todos) {
        if ($hayFont) {
            $f = $fuentes[$c]
            $c.Font = New-Object System.Drawing.Font($f.FontFamily, [single]($f.Size * $script:FontK), $f.Style, $f.Unit)
        }
        if ($hayPx -and $c.Tag -is [hashtable] -and $c.Tag.ContainsKey('Radius')) {
            $c.Tag.Radius = [int][Math]::Round($c.Tag.Radius * $script:Px)
        }
        if ($hayPx -and $columnas.ContainsKey($c)) {
            for ($i = 0; $i -lt $c.Columns.Count; $i++) { $c.Columns[$i].Width = [int]($columnas[$c][$i] * $script:Px) }
        }
    }
}

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $d = [Math]::Min($r * 2, [Math]::Min($w, $h))
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc($x, $y, $d, $d, 180, 90)
    $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}

function Get-Shade($c, [double]$k) {
    # k > 0 aclara hacia blanco; k < 0 oscurece hacia negro
    $t = if ($k -ge 0) { 255 } else { 0 }
    $a = [Math]::Abs($k)
    [System.Drawing.Color]::FromArgb(
        [int]($c.R + ($t - $c.R) * $a), [int]($c.G + ($t - $c.G) * $a), [int]($c.B + ($t - $c.B) * $a))
}

function Set-Rounded($ctl, [int]$r) {
    # Panel/tarjeta con fondo redondeado pintado. Se llama ANTES de agregar
    # otros Paint, así el fondo queda debajo de lo que dibuje el control.
    $ctl.Tag = @{ Radius = $r; Fill = $ctl.BackColor }
    $ctl.BackColor = $colBg
    $ctl.Add_Paint({
        param($s, $e)
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $gp = New-RoundPath 0 0 ($s.Width - 1) ($s.Height - 1) $s.Tag.Radius
            $br = New-Object System.Drawing.SolidBrush($s.Tag.Fill)
            $e.Graphics.FillPath($br, $gp)
            $br.Dispose(); $gp.Dispose()
        } catch {}
    })
}

function Invoke-PaintControl($s, $g) {
    # Pinta un botón o un toggle entero: fondo del padre, pastilla redondeada
    # con hover/presionado, y el texto. En los toggles, además, el interruptor.
    try {
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($(if ($s.Parent) { $s.Parent.BackColor } else { $colBg }))
        $esToggle = $s -is [System.Windows.Forms.CheckBox]
        $on   = $esToggle -and $s.Checked
        $fill = if ($esToggle) { if ($on) { Get-Shade $colAccent -0.72 } else { $colPanel } } else { $s.BackColor }
        if ($s.Tag.Down) { $fill = Get-Shade $fill -0.14 } elseif ($s.Tag.Hover) { $fill = Get-Shade $fill 0.09 }

        $gp = New-RoundPath 0 0 ($s.Width - 1) ($s.Height - 1) $s.Tag.Radius
        if ($s.Tag.Gradient) {
            $rect = New-Object System.Drawing.RectangleF(0, 0, $s.Width, $s.Height)
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $fill, (Get-Shade $colBlue $(if ($s.Tag.Hover) { 0.09 } else { 0 })), 0.0)
        } else {
            $br = New-Object System.Drawing.SolidBrush($fill)
        }
        $g.FillPath($br, $gp)
        $br.Dispose()

        if ($esToggle) {
            # Borde fino + interruptor a la izquierda
            $pen = New-Object System.Drawing.Pen($(if ($on) { $colAccent } else { $colSurface }), 1.2)
            $g.DrawPath($pen, $gp); $pen.Dispose()
            $k = $script:Px
            $swW = 30 * $k; $swH = 16 * $k; $sx = 12 * $k; $sy = [int](($s.Height - $swH) / 2)
            $sp = New-RoundPath $sx $sy $swW $swH (8 * $k)
            $sb = New-Object System.Drawing.SolidBrush($(if ($on) { $colAccent } else { $colSurface }))
            $g.FillPath($sb, $sp); $sb.Dispose(); $sp.Dispose()
            $kx = if ($on) { $sx + $swW - $swH + 2 * $k } else { $sx + 2 * $k }
            $kb = New-Object System.Drawing.SolidBrush($(if ($on) { $colDark } else { $colDim }))
            $g.FillEllipse($kb, $kx, ($sy + 2 * $k), ($swH - 4 * $k), ($swH - 4 * $k)); $kb.Dispose()
            $tb = New-Object System.Drawing.SolidBrush($(if ($on) { $colText } else { $colDim }))
            $tr = New-Object System.Drawing.RectangleF(($sx + $swW + 8 * $k), 0, ($s.Width - $sx - $swW - 14 * $k), $s.Height)
            $g.DrawString($s.Text, $s.Font, $tb, $tr, $script:sfLeft); $tb.Dispose()
        } else {
            $tb = New-Object System.Drawing.SolidBrush($s.ForeColor)
            $tr = New-Object System.Drawing.RectangleF(0, 0, $s.Width, $s.Height)
            $g.DrawString($s.Text, $s.Font, $tb, $tr, $script:sfCenter); $tb.Dispose()
        }
        $gp.Dispose()
    } catch {}
}

function Add-ControlPaint($c, [int]$r) {
    $c.Tag = @{ Radius = $r; Hover = $false; Down = $false; Gradient = $false }
    $c.Add_MouseEnter({ $this.Tag.Hover = $true;  $this.Invalidate() })
    $c.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Tag.Down = $false; $this.Invalidate() })
    $c.Add_MouseDown({  $this.Tag.Down  = $true;  $this.Invalidate() })
    $c.Add_MouseUp({    $this.Tag.Down  = $false; $this.Invalidate() })
    $c.Add_Paint({ param($s, $e) Invoke-PaintControl $s $e.Graphics })
}

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $bg, $fg, $parent) {
    if (-not $parent) { $parent = $form }
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $text
    $b.Location  = New-Object System.Drawing.Point($x, $y)
    $b.Size      = New-Object System.Drawing.Size($w, $h)
    $b.BackColor = $bg
    $b.ForeColor = $fg
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $b.Cursor    = 'Hand'
    $b.TabStop   = $false
    Add-ControlPaint $b 9
    $parent.Controls.Add($b)
    return $b
}

function New-Toggle([string]$text, [int]$x, [int]$y, [int]$w, $parent) {
    # Interruptor: apagado gris, encendido mauve con la perilla a la derecha
    if (-not $parent) { $parent = $form }
    $t = New-Object System.Windows.Forms.CheckBox
    $t.Appearance = 'Button'
    $t.Text       = $text
    $t.Location   = New-Object System.Drawing.Point($x, $y)
    $t.Size       = New-Object System.Drawing.Size($w, 36)
    $t.FlatStyle  = 'Flat'
    $t.FlatAppearance.BorderSize = 0
    $t.BackColor  = $colPanel
    $t.ForeColor  = $colText
    $t.Cursor     = 'Hand'
    $t.TabStop    = $false
    Add-ControlPaint $t 18
    $t.Add_CheckedChanged({ $this.Invalidate() })
    $parent.Controls.Add($t)
    return $t
}

# Ventana, listas y barras de scroll en oscuro (APIs de tema de Windows)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BoosterUi {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    static extern int SetPreferredAppMode(int mode);
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);

    public static void AllowDark() { try { SetPreferredAppMode(1); } catch { } }
    public static void DarkTitle(IntPtr h) {
        try { int v = 1; if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4); } catch { }
    }
    public static void DarkScroll(IntPtr h) { try { SetWindowTheme(h, "DarkMode_Explorer", null); } catch { } }
    public static void DarkList(IntPtr h) {
        try {
            SetWindowTheme(h, "DarkMode_Explorer", null);
            IntPtr hdr = SendMessage(h, 0x101F, IntPtr.Zero, IntPtr.Zero);   // LVM_GETHEADER
            if (hdr != IntPtr.Zero) SetWindowTheme(hdr, "DarkMode_ItemsView", null);
        } catch { }
    }
}
"@
[BoosterUi]::AllowDark()

# Filas más altas en las listas (truco: un ImageList de 1 px de ancho)
$script:RowImgs = New-Object System.Windows.Forms.ImageList
$script:RowImgs.ImageSize = New-Object System.Drawing.Size(1, 26)

function Set-DarkList($lv) {
    # Encabezado pintado en oscuro, filas con aire y scroll oscuro
    $lv.OwnerDraw      = $true
    $lv.SmallImageList = $script:RowImgs
    # La última columna ocupa lo que sobra: sin esto queda un bloque de
    # encabezado vacío de otro color a la derecha
    if ($lv.Columns.Count -gt 0) {
        $usado = 0
        for ($i = 0; $i -lt $lv.Columns.Count - 1; $i++) { $usado += $lv.Columns[$i].Width }
        $resto = $lv.Width - $usado - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
        if ($resto -gt 40) { $lv.Columns[$lv.Columns.Count - 1].Width = $resto }
    }
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $e.Graphics.FillRectangle($script:uiBrHead, $e.Bounds)
        $r = New-Object System.Drawing.RectangleF(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 10), $e.Bounds.Height)
        $e.Graphics.DrawString($e.Header.Text.ToUpper(), $script:uiFontHead, $script:uiBrDim, $r, $script:sfLeft)
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_HandleCreated({ [BoosterUi]::DarkList($this.Handle) })
}

function New-BoosterIcon {
    # Ícono propio (rayo sobre degradé mauve-azul) para la ventana y la bandeja
    $bmp = New-Object System.Drawing.Bitmap(64, 64)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gp = New-RoundPath 2 2 60 60 15
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle(0, 0, 64, 64)), $colAccent, $colBlue, 45.0)
    $g.FillPath($br, $gp)
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF(37, 7)),  (New-Object System.Drawing.PointF(15, 36)),
        (New-Object System.Drawing.PointF(29, 36)), (New-Object System.Drawing.PointF(25, 57)),
        (New-Object System.Drawing.PointF(49, 26)), (New-Object System.Drawing.PointF(35, 26)))
    $bb = New-Object System.Drawing.SolidBrush($colBg)
    $g.FillPolygon($bb, $pts)
    $bb.Dispose(); $br.Dispose(); $gp.Dispose(); $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$script:BoosterIcon = New-BoosterIcon
$form.Icon = $script:BoosterIcon
$form.Text = 'Booster'
$form.Add_HandleCreated({ [BoosterUi]::DarkTitle($form.Handle) })

function Set-AllChecks($lv) {
    # Autoseleccionador: tilda todo; si ya estaba todo tildado, destilda todo
    if ($lv.Items.Count -eq 0) { return }
    $faltan = @($lv.Items | Where-Object { -not $_.Checked }).Count
    $nuevo = ($faltan -gt 0)
    foreach ($item in $lv.Items) { $item.Checked = $nuevo }
}

# ----- Header -----
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'BOOSTER'
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $colAccent
$lblTitle.Location  = New-Object System.Drawing.Point(24, 8)
$lblTitle.AutoSize  = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'Liberá tu PC después del trabajo'
$lblSub.ForeColor = $colDim
$lblSub.Location  = New-Object System.Drawing.Point(28, 52)
$lblSub.AutoSize  = $true
$form.Controls.Add($lblSub)

# Chip de versión al lado del título y línea fina que separa la cabecera
$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text      = "v$($script:BoosterVersion)"
$lblVer.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblVer.ForeColor = $colAccent
$lblVer.BackColor = $colPanel
$lblVer.TextAlign = 'MiddleCenter'
$lblVer.Location  = New-Object System.Drawing.Point(192, 22)
$lblVer.Size      = New-Object System.Drawing.Size(34, 20)
$form.Controls.Add($lblVer)

$sepHeader = New-Object System.Windows.Forms.Panel
$sepHeader.Location  = New-Object System.Drawing.Point(24, 74)
$sepHeader.Size      = New-Object System.Drawing.Size(1116, 1)
$sepHeader.BackColor = $colPanel
$form.Controls.Add($sepHeader)

$chkTimer = New-Toggle 'Timer 0,5 ms' 490 20 150
$chkTimer.Add_CheckedChanged({ Set-TimerResolution $chkTimer.Checked })

$chkPCores = New-Toggle 'Solo P-cores' 648 20 150
$chkPCores.Visible = $script:CpuHibrido
$chkPCores.Add_CheckedChanged({
    # Se aplica en el acto a los juegos que ya estén corriendo: prendelo y
    # apagalo con el juego abierto y mirá los FPS para saber si te sirve.
    $juegos = Get-GameProcesses
    foreach ($p in $juegos) { Set-GameAffinity $p $chkPCores.Checked }
    if ($chkPCores.Checked) {
        Write-Log ("Solo P-cores ON: los juegos se fijan a los {0} núcleos de rendimiento (los {1} E quedan para lo demás)." -f $script:CpuTopo[2], $script:CpuTopo[3]) 'info'
        if ($juegos.Count -eq 0) { Write-Log 'No hay un juego abierto ahora: se aplica cuando lo detecte.' 'info' }
    } else {
        Write-Log 'Solo P-cores desactivado.' 'info'
    }
})

$chkAuto = New-Toggle 'Auto-gaming' 806 20 150
$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) {
        Write-Log "Auto-gaming ON: al detectar un juego (lista 'juegos' del config) se activa el modo gaming solo, sin diálogos." 'info'
        if ($script:Sigilo) { Write-Log 'Ya hay un juego abierto: tocá MODO GAMING si querés aplicarlo ahora.' 'info' }
    } else {
        Write-Log 'Auto-gaming desactivado.' 'info'
    }
})

$btnGaming = New-Btn 'MODO GAMING' 966 14 174 48 $colAccent $colDark $form
$btnGaming.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$btnGaming.Tag.Gradient = $true
$btnGaming.Tag.Radius   = 12
$btnGaming.Add_Click({ Invoke-GamingMode })

# ----- Navegación de páginas -----
$btnNavLimpieza = New-Btn 'Limpieza' 24 84 130 34 $colSurface $colText $form
$btnNavRecursos = New-Btn 'Recursos' 162 84 130 34 $colSurface $colText $form
$btnNavPro      = New-Btn 'Pro'      300 84 130 34 $colSurface $colText $form
$btnNavDiag     = New-Btn 'Diagnóstico' 438 84 130 34 $colSurface $colText $form

$pageLimpieza = New-Object System.Windows.Forms.Panel
$pageRecursos = New-Object System.Windows.Forms.Panel
$pagePro      = New-Object System.Windows.Forms.Panel
$pageDiag     = New-Object System.Windows.Forms.Panel
foreach ($pg in @($pageLimpieza, $pageRecursos, $pagePro, $pageDiag)) {
    $pg.Location  = New-Object System.Drawing.Point(24, 130)
    $pg.Size      = New-Object System.Drawing.Size(1116, 540)
    $pg.BackColor = $colBg
    $pg.Visible   = $false
    $form.Controls.Add($pg)
}

function Show-Page([string]$name) {
    $pageLimpieza.Visible = ($name -eq 'limpieza')
    $pageRecursos.Visible = ($name -eq 'recursos')
    $pagePro.Visible      = ($name -eq 'pro')
    $pageDiag.Visible     = ($name -eq 'diag')
    foreach ($par in @(@($btnNavLimpieza, 'limpieza'), @($btnNavRecursos, 'recursos'), @($btnNavPro, 'pro'), @($btnNavDiag, 'diag'))) {
        $activo = ($par[1] -eq $name)
        $par[0].BackColor = if ($activo) { $colAccent } else { $colSurface }
        $par[0].ForeColor = if ($activo) { $colDark } else { $colText }
    }
}
$btnNavLimpieza.Add_Click({ Show-Page 'limpieza' })
$btnNavRecursos.Add_Click({ Show-Page 'recursos' })
$btnNavPro.Add_Click({ Show-Page 'pro' })
$btnNavDiag.Add_Click({ Show-Page 'diag' })

# ================= PÁGINA LIMPIEZA =================
$lblProc = New-Object System.Windows.Forms.Label
$lblProc.Text      = 'PROCESOS TRAGONES'
$lblProc.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblProc.ForeColor = $colDim
$lblProc.Location  = New-Object System.Drawing.Point(0, 0)
$lblProc.AutoSize  = $true
$pageLimpieza.Controls.Add($lblProc)

$lvProc = New-Object System.Windows.Forms.ListView
$lvProc.Location      = New-Object System.Drawing.Point(0, 22)
$lvProc.Size          = New-Object System.Drawing.Size(660, 452)
$lvProc.View          = 'Details'
$lvProc.CheckBoxes    = $true
$lvProc.FullRowSelect = $true
$lvProc.BackColor     = $colPanel
$lvProc.ForeColor     = $colText
$lvProc.BorderStyle   = 'None'
[void]$lvProc.Columns.Add('Proceso', 235)
[void]$lvProc.Columns.Add('Instancias', 80)
[void]$lvProc.Columns.Add('RAM (MB)', 105)
[void]$lvProc.Columns.Add('CPU (%)', 80)
[void]$lvProc.Columns.Add('Fondo', 65)
Set-DarkList $lvProc
$pageLimpieza.Controls.Add($lvProc)

function Refresh-ProcessList {
    $form.Cursor = 'WaitCursor'
    $lvProc.Items.Clear()
    foreach ($g in (Get-ProcessSnapshot)) {
        $item = New-Object System.Windows.Forms.ListViewItem($g.Name)
        [void]$item.SubItems.Add([string]$g.Count)
        [void]$item.SubItems.Add(([Math]::Round($g.RamMB)).ToString('N0'))
        [void]$item.SubItems.Add([string]$g.CpuPct)
        [void]$item.SubItems.Add($(if ($g.EsServidor) { 'SERVER' } elseif ($g.TieneVentana) { '' } else { 'Sí' }))
        if ($g.EsServidor) { $item.ForeColor = $colBlue }
        elseif ($g.CpuPct -ge 15 -or $g.RamMB -ge 800) { $item.ForeColor = $colRed }
        [void]$lvProc.Items.Add($item)
    }
    $form.Cursor = 'Default'
}

$lblSvc = New-Object System.Windows.Forms.Label
$lblSvc.Text      = 'SERVICIOS (WINDOWS + TERCEROS)'
$lblSvc.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblSvc.ForeColor = $colDim
$lblSvc.Location  = New-Object System.Drawing.Point(676, 0)
$lblSvc.AutoSize  = $true
$pageLimpieza.Controls.Add($lblSvc)

$lvSvc = New-Object System.Windows.Forms.ListView
$lvSvc.Location      = New-Object System.Drawing.Point(676, 22)
$lvSvc.Size          = New-Object System.Drawing.Size(440, 452)
$lvSvc.View          = 'Details'
$lvSvc.CheckBoxes    = $true
$lvSvc.FullRowSelect = $true
$lvSvc.BackColor     = $colPanel
$lvSvc.ForeColor     = $colText
$lvSvc.BorderStyle   = 'None'
[void]$lvSvc.Columns.Add('Servicio', 225)
[void]$lvSvc.Columns.Add('Estado', 95)
[void]$lvSvc.Columns.Add('Origen', 85)
Set-DarkList $lvSvc
$pageLimpieza.Controls.Add($lvSvc)

function Refresh-ServiceList {
    $lvSvc.Items.Clear()
    $agregados = @{}
    foreach ($svcName in $Config.serviciosPausables) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $estado = if (-not $svc) { 'No existe' } elseif ($svc.Status -eq 'Running') { 'Corriendo' } else { 'Pausado' }
        $item = New-Object System.Windows.Forms.ListViewItem($svcName)
        [void]$item.SubItems.Add($estado)
        [void]$item.SubItems.Add('Windows')
        $item.ForeColor = if ($estado -eq 'Corriendo') { $colGreen } else { $colDim }
        [void]$lvSvc.Items.Add($item)
        $agregados[$svcName] = $true
    }
    foreach ($svc in (Get-ThirdPartyServices)) {
        if ($agregados.ContainsKey($svc.Name)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($svc.Name)
        [void]$item.SubItems.Add('Corriendo')
        [void]$item.SubItems.Add('Terceros')
        $item.ForeColor = $colGreen
        $item.ToolTipText = $svc.DisplayName
        [void]$lvSvc.Items.Add($item)
        $agregados[$svc.Name] = $true
    }
    # Servicios de terceros que Booster pausó (para que se vean y se puedan restaurar)
    foreach ($svcName in @((Get-State).servicios)) {
        if (-not $svcName -or $agregados.ContainsKey($svcName)) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($svcName)
        [void]$item.SubItems.Add('Pausado')
        [void]$item.SubItems.Add('Terceros')
        $item.ForeColor = $colDim
        [void]$lvSvc.Items.Add($item)
    }
}

$btnProcAll = New-Btn 'Tildar todo' 0 490 120 36 $colSurface $colText $pageLimpieza
$btnProcAll.Add_Click({ Set-AllChecks $lvProc })

$btnKill = New-Btn 'Cerrar tildados' 128 490 140 36 $colRed $colDark $pageLimpieza
$btnKill.Add_Click({
    $marcados = @($lvProc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay procesos tildados.' 'warn'
        return
    }
    Close-ProcessesByName $marcados
    Refresh-ProcessList
})

$btnRefresh = New-Btn 'Actualizar' 276 490 110 36 $colSurface $colText $pageLimpieza
$btnRefresh.Add_Click({ Refresh-ProcessList; Refresh-ServiceList })

$btnSvcAll = New-Btn 'Tildar todo' 676 490 120 36 $colSurface $colText $pageLimpieza
$btnSvcAll.Add_Click({ Set-AllChecks $lvSvc })

$btnSvcStop = New-Btn 'Pausar tildados' 804 490 140 36 $colSurface $colText $pageLimpieza
$btnSvcStop.Add_Click({
    $marcados = @($lvSvc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay servicios tildados.' 'warn'
        return
    }
    [void](Stop-ServicesByName $marcados)
    Refresh-ServiceList
})

$btnSvcStart = New-Btn 'Restaurar todo' 952 490 130 36 $colSurface $colText $pageLimpieza
$btnSvcStart.Add_Click({ Restore-Services })

# ================= PÁGINA RECURSOS =================
$script:RamHist          = New-Object System.Collections.ArrayList
$script:PurgeMarks       = New-Object System.Collections.ArrayList
$script:TickNum          = 0
$script:HistCap          = 180      # 3 minutos de historia a 1 muestra/seg
$script:PurgadoSesionMB  = 0
$script:TotalRamMB       = ([BoosterRam]::Query())[0]
$script:Sigilo           = $false
$script:JuegoPids        = @()
$script:WatchOk          = $false
$script:PingTask         = $null
$script:BoostEnCurso     = $false
$script:PingHist         = New-Object System.Collections.ArrayList
$script:Pinger           = New-Object System.Net.NetworkInformation.Ping
$script:UltimaAutoPurga  = -999
$script:GpuOk            = $null -ne (Get-Command nvidia-smi -ErrorAction SilentlyContinue)

# Recursos GDI creados una sola vez (crearlos en cada Paint filtra handles)
# Fuentes de los gráficos en PÍXELES (no puntos): los gráficos se dibujan en
# coordenadas lógicas y un ScaleTransform los lleva a la escala real, así que
# la fuente no tiene que escalar por su cuenta con el DPI.
$pxUnit = [System.Drawing.GraphicsUnit]::Pixel
$script:cFontCap  = New-Object System.Drawing.Font('Segoe UI Semibold', 11.33, [System.Drawing.FontStyle]::Regular, $pxUnit)
$script:cFontTiny = New-Object System.Drawing.Font('Segoe UI', 10.67, [System.Drawing.FontStyle]::Regular, $pxUnit)
$script:cFontBig  = New-Object System.Drawing.Font('Segoe UI', 21.33, [System.Drawing.FontStyle]::Bold, $pxUnit)
$script:cBrDim    = New-Object System.Drawing.SolidBrush($colDim)
$script:cBrAccent = New-Object System.Drawing.SolidBrush($colAccent)
$script:cBrGreen  = New-Object System.Drawing.SolidBrush($colGreen)
$script:cBrHalo   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, $colAccent))
$script:cPenGrid  = New-Object System.Drawing.Pen($colSurface, 1)
$script:cPenLine  = New-Object System.Drawing.Pen($colAccent, 2.2)
$script:cPenLine.LineJoin = 'Round'
$script:cPenMark  = New-Object System.Drawing.Pen($colGreen, 1.4)
$script:cPenMark.DashStyle = 'Dash'
$script:cBrText2  = New-Object System.Drawing.SolidBrush($colText)
$script:cBrYellow = New-Object System.Drawing.SolidBrush($colYellow)
$script:cBrRed2   = New-Object System.Drawing.SolidBrush($colRed)
$script:cBrBlue   = New-Object System.Drawing.SolidBrush($colBlue)
$script:cPenPing  = New-Object System.Drawing.Pen($colBlue, 2)
$script:cPenPing.LineJoin = 'Round'

$chartPanel = New-Object System.Windows.Forms.Panel
$chartPanel.Location  = New-Object System.Drawing.Point(0, 0)
$chartPanel.Size      = New-Object System.Drawing.Size(1116, 225)
$chartPanel.BackColor = $colPanel
Set-Rounded $chartPanel 12
# DoubleBuffered es protected en Panel: se activa por reflexión para que no parpadee
[System.Windows.Forms.Panel].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($chartPanel, $true, $null)
$pageRecursos.Controls.Add($chartPanel)

$chartPanel.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        # Se dibuja en coordenadas lógicas (96 dpi) y se escala todo junto
        $g.ScaleTransform($script:Px, $script:Px)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $W = $sender.ClientSize.Width / $script:Px; $H = $sender.ClientSize.Height / $script:Px
        $padL = 18; $padR = 84; $padT = 46; $padB = 18
        $plotW = $W - $padL - $padR; $plotH = $H - $padT - $padB

        # Título + leyenda de purgas
        $g.DrawString('RAM EN VIVO', $cFontCap, $cBrDim, 18, 14)
        $g.DrawLine($cPenMark, 120, 22, 142, 22)
        $g.DrawString('purga', $cFontTiny, $cBrGreen, 146, 15)

        $hist = @($script:RamHist)
        if ($hist.Count -ge 1) {
            # Valor actual grande, arriba a la derecha
            $ultimo = $hist[$hist.Count - 1]
            $txt = ('{0:N1} GB' -f ($ultimo.UsedMB / 1024))
            $szB = $g.MeasureString($txt, $cFontBig)
            $g.DrawString($txt, $cFontBig, $cBrAccent, $W - 18 - $szB.Width, 8)
            $sub = ('en uso de {0:N0} GB' -f ($script:TotalRamMB / 1024))
            $szS = $g.MeasureString($sub, $cFontTiny)
            # El subtítulo va a la izquierda del valor (abajo pisaba las etiquetas del eje)
            $g.DrawString($sub, $cFontTiny, $cBrDim, ($W - 18 - $szB.Width - $szS.Width - 6), (8 + $szB.Height - $szS.Height - 7))
        }
        if ($hist.Count -lt 2) {
            $g.DrawString('Recolectando datos...', $cFontCap, $cBrDim, $padL, $padT + $plotH / 2)
            return
        }

        # Escala Y dinámica: zoom al rango real para que las purgas se VEAN
        $vals = $hist | ForEach-Object { $_.UsedMB }
        $minV = ($vals | Measure-Object -Minimum).Minimum
        $maxV = ($vals | Measure-Object -Maximum).Maximum
        $rango = [Math]::Max($maxV - $minV, $script:TotalRamMB * 0.04)
        $yMin = [Math]::Max(0, $minV - $rango * 0.25)
        $yMax = $maxV + $rango * 0.25

        # Grilla horizontal con etiquetas en GB
        for ($i = 0; $i -le 3; $i++) {
            $y = $padT + $plotH * $i / 3
            $g.DrawLine($cPenGrid, $padL, $y, $padL + $plotW, $y)
            $v = $yMax - ($yMax - $yMin) * $i / 3
            $g.DrawString(('{0:N1} GB' -f ($v / 1024)), $cFontTiny, $cBrDim, $padL + $plotW + 8, $y - 8)
        }

        # Puntos de la curva (ventana fija anclada a la derecha, avanza como ticker)
        $lastTick = $hist[$hist.Count - 1].Tick
        $firstTick = $hist[0].Tick
        $step = $plotW / [Math]::Max(1, ($script:HistCap - 1))
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($m in $hist) {
            $x = $padL + $plotW - ($lastTick - $m.Tick) * $step
            $frac = ($m.UsedMB - $yMin) / ($yMax - $yMin)
            $y = $padT + $plotH * (1 - $frac)
            $pts.Add((New-Object System.Drawing.PointF($x, $y)))
        }

        # Área bajo la curva con gradiente mauve -> transparente
        $area = New-Object System.Drawing.Drawing2D.GraphicsPath
        $area.AddLines($pts.ToArray())
        $area.AddLine($pts[$pts.Count - 1].X, ($padT + $plotH), $pts[0].X, ($padT + $plotH))
        $area.CloseFigure()
        $rect = New-Object System.Drawing.RectangleF($padL, $padT, $plotW, ($plotH + 1))
        $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(105, $colAccent), [System.Drawing.Color]::FromArgb(0, $colAccent), 90.0)
        $g.FillPath($grad, $area)
        $grad.Dispose(); $area.Dispose()

        # Línea principal + punto vivo con halo
        $g.DrawLines($cPenLine, $pts.ToArray())
        $pu = $pts[$pts.Count - 1]
        $g.FillEllipse($cBrHalo, ($pu.X - 7), ($pu.Y - 7), 14, 14)
        $g.FillEllipse($cBrAccent, ($pu.X - 3.5), ($pu.Y - 3.5), 7, 7)

        # Marcas de purga: línea vertical verde + GB liberados
        foreach ($mk in @($script:PurgeMarks)) {
            if ($mk.Tick -lt $firstTick) { continue }
            $x = $padL + $plotW - ($lastTick - $mk.Tick) * $step
            $g.DrawLine($cPenMark, $x, $padT, $x, ($padT + $plotH))
            $lbl = 'PURGA ' + $mk.Texto
            $sz = $g.MeasureString($lbl, $cFontTiny)
            $lx = [Math]::Max($padL, [Math]::Min($x - $sz.Width / 2, $padL + $plotW - $sz.Width))
            $g.DrawString($lbl, $cFontTiny, $cBrGreen, $lx, ($padT - 17))
        }
    } catch {
        # Nunca dejar que una excepción de dibujo tumbe la app (la X roja)
    }
})

# ----- Gráfico de ping en vivo -----
$pingPanel = New-Object System.Windows.Forms.Panel
$pingPanel.Location  = New-Object System.Drawing.Point(0, 237)
$pingPanel.Size      = New-Object System.Drawing.Size(1116, 125)
$pingPanel.BackColor = $colPanel
Set-Rounded $pingPanel 12
[System.Windows.Forms.Panel].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($pingPanel, $true, $null)
$pageRecursos.Controls.Add($pingPanel)

$pingPanel.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        # Se dibuja en coordenadas lógicas (96 dpi) y se escala todo junto
        $g.ScaleTransform($script:Px, $script:Px)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $W = $sender.ClientSize.Width / $script:Px; $H = $sender.ClientSize.Height / $script:Px
        $padL = 18; $padR = 84; $padT = 46; $padB = 12
        $plotW = $W - $padL - $padR; $plotH = $H - $padT - $padB

        $g.DrawString($(if ($script:Sigilo) { 'PING - en pausa (modo sigilo)' } else { 'PING EN VIVO - 1.1.1.1' }), $cFontCap, $cBrDim, 18, 9)

        $hist = @($script:PingHist)
        if ($hist.Count -ge 1) {
            $ms = $hist[$hist.Count - 1].Ms
            $brUlt = if ($ms -lt 35) { $cBrGreen } elseif ($ms -lt 70) { $cBrText2 } elseif ($ms -lt 110) { $cBrYellow } else { $cBrRed2 }
            $txt = ('{0} ms' -f $ms)
            $sz = $g.MeasureString($txt, $cFontBig)
            $g.DrawString($txt, $cFontBig, $brUlt, ($W - 18 - $sz.Width), 5)
            $ult = @($hist | Select-Object -Last 30 | ForEach-Object { $_.Ms })
            if ($ult.Count -gt 1) {
                $j = 0.0
                for ($i = 1; $i -lt $ult.Count; $i++) { $j += [Math]::Abs($ult[$i] - $ult[$i - 1]) }
                $j = [Math]::Round($j / ($ult.Count - 1), 1)
                $sub = "jitter $j ms"
                $szS = $g.MeasureString($sub, $cFontTiny)
                $g.DrawString($sub, $cFontTiny, $cBrDim, ($W - 18 - $sz.Width - $szS.Width - 6), (5 + $sz.Height - $szS.Height - 7))
            }
        }
        if ($hist.Count -lt 2) {
            $g.DrawString('Recolectando datos...', $cFontCap, $cBrDim, $padL, ($padT + $plotH / 2))
            return
        }

        $vals = $hist | ForEach-Object { $_.Ms }
        $maxV = ($vals | Measure-Object -Maximum).Maximum
        $yMax = [Math]::Max(40, $maxV * 1.25)

        for ($i = 0; $i -le 2; $i++) {
            $y = $padT + $plotH * $i / 2
            $g.DrawLine($cPenGrid, $padL, $y, ($padL + $plotW), $y)
            $v = $yMax * (1 - $i / 2)
            $g.DrawString(('{0:N0} ms' -f $v), $cFontTiny, $cBrDim, ($padL + $plotW + 8), ($y - 8))
        }

        $lastTick = $hist[$hist.Count - 1].Tick
        $step = $plotW / [Math]::Max(1, ($script:HistCap - 1))
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($m in $hist) {
            $x = $padL + $plotW - ($lastTick - $m.Tick) * $step
            $y = $padT + $plotH * (1 - ([Math]::Min($m.Ms, $yMax) / $yMax))
            $pts.Add((New-Object System.Drawing.PointF($x, $y)))
        }
        $g.DrawLines($cPenPing, $pts.ToArray())
        $pu = $pts[$pts.Count - 1]
        $g.FillEllipse($cBrBlue, ($pu.X - 3), ($pu.Y - 3), 6, 6)
    } catch {
        # Nunca dejar que una excepción de dibujo tumbe la app
    }
})

function New-Card([string]$caption, [int]$x, $valColor) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point($x, 374)
    $p.Size      = New-Object System.Drawing.Size(213, 66)
    $p.BackColor = $colPanel
    Set-Rounded $p 10
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text      = $caption
    $cap.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.25)
    $cap.ForeColor = $colDim
    $cap.BackColor = $colPanel
    $cap.Location  = New-Object System.Drawing.Point(14, 9)
    $cap.AutoSize  = $true
    $p.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text      = '—'
    $val.Font      = New-Object System.Drawing.Font('Segoe UI', 13.5, [System.Drawing.FontStyle]::Bold)
    $val.ForeColor = $valColor
    $val.BackColor = $colPanel
    $val.Location  = New-Object System.Drawing.Point(12, 27)
    $val.AutoSize  = $true
    $p.Controls.Add($val)
    $pageRecursos.Controls.Add($p)
    return $val
}

$lblCardUsada = New-Card 'RAM EN USO'     0   $colAccent
$lblCardLibre = New-Card 'RAM LIBRE'      225 $colGreen
$lblCardGpu   = New-Card 'GPU'            450 $colBlue
$lblCardVram  = New-Card 'VRAM'           675 $colBlue
$lblCardPurga = New-Card 'PURGADO SESIÓN' 900 $colTeal

$btnPurge = New-Btn 'Purgar RAM caché' 0 456 220 46 $colTeal $colDark $pageRecursos
$btnPurge.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$btnPurge.Add_Click({ Clear-StandbyMemory })

$chkAutoPurga = New-Toggle 'Auto-purga' 232 461 140 $pageRecursos
$chkAutoPurga.Add_CheckedChanged({
    if ($chkAutoPurga.Checked) {
        Write-Log ("Auto-purga ON: si la RAM libre baja de {0:N0} MB purgo solo (máximo una vez cada 2 minutos)." -f $Config.autoPurgaLibreMB) 'info'
    } else {
        Write-Log 'Auto-purga desactivada.' 'info'
    }
})

$lblPurgeHint = New-Object System.Windows.Forms.Label
$lblPurgeHint.Text      = "La caché standby se convierte en RAM libre (estilo ISLC); cada purga queda marcada en verde. La auto-purga viene apagada:`ncon RAM de sobra no suma, y purgar en plena partida obliga a releer del disco. Umbral: 'autoPurgaLibreMB' del config.json."
$lblPurgeHint.ForeColor = $colDim
$lblPurgeHint.Location  = New-Object System.Drawing.Point(378, 458)
$lblPurgeHint.Size      = New-Object System.Drawing.Size(738, 42)
$pageRecursos.Controls.Add($lblPurgeHint)

# ================= PÁGINA PRO =================
function New-ProRow([string]$text, [int]$y, $bg, $fg, [string]$desc) {
    $b = New-Btn $text 0 $y 210 40 $bg $fg $pagePro
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $desc
    $l.ForeColor = $colDim
    $l.Location  = New-Object System.Drawing.Point(230, ($y + 2))
    $l.Size      = New-Object System.Drawing.Size(880, 38)
    $pagePro.Controls.Add($l)
    return $b
}

$lblPro = New-Object System.Windows.Forms.Label
$lblPro.Text      = 'HERRAMIENTAS PRO — todo con backup y reversible'
$lblPro.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblPro.ForeColor = $colDim
$lblPro.Location  = New-Object System.Drawing.Point(0, 0)
$lblPro.AutoSize  = $true
$pagePro.Controls.Add($lblPro)

$btnNetOpt = New-ProRow 'Optimizar PC' 30 $colAccent $colDark "Tweaks persistentes (una sola vez): GameDVR apagado, ahorro de energía de placa de red/USB desactivado y red sin throttling ni Nagle (Nagle solo afecta a juegos por TCP; los que van por UDP, como Valorant o CS2, no lo notan). Con backup."
$btnNetOpt.Add_Click({ Optimize-System })

$btnNetUndo = New-ProRow 'Revertir tweaks' 96 $colSurface $colText "Deshace todo lo de Optimizar PC restaurando los valores exactos que tenía tu PC, desde los backups."
$btnNetUndo.Add_Click({ Restore-Tweaks })

$btnPing = New-ProRow 'Test ping' 162 $colBlue $colDark "Mide latencia promedio, mínima/máxima y jitter contra 1.1.1.1 y 8.8.8.8. Resultados en el registro. Ideal antes y después de optimizar."
$btnPing.Add_Click({ Test-PingLatency })

$btnStartup = New-ProRow 'Apps de inicio' 228 $colSurface $colText "Elegí qué programas arrancan junto con Windows. Usa la misma mecánica que el Administrador de tareas: no borra nada y es 100% reversible."
$btnStartup.Add_Click({ Show-StartupManager })

$btnWork = New-ProRow 'Modo trabajo' 294 $colGreen $colDark "El botón inverso: restaura servicios y plan de energía, apaga el auto-gaming y te abre las apps de la lista 'abrirEnTrabajo' del config.json. El lunes empieza con un click."
$btnWork.Add_Click({ Invoke-WorkMode })

$btnJunk = New-ProRow 'Limpiar basura' 360 $colYellow $colDark "Borra temporales de Windows y cachés de shaders viejos (DirectX/NVIDIA). Los shaders se regeneran solos: la primera carga del juego puede tardar un toque más, y de paso cura stutters por caché corrupta."
$btnJunk.Add_Click({ Clear-Junk })

$btnRescate = New-ProRow 'Rescate antimalware' 426 $colRed $colDark "¿La cuenta de Discord manda spam sola (regalos de MrBeast, casinos cripto)? Le robaron el token. Abre Booster Rescate: busca el cliente de Discord parcheado y la persistencia del ladron, y te da la guia para recuperar la cuenta."
$btnRescate.Add_Click({
    $rescate = Join-Path $script:Dir 'Rescate.ps1'
    if (-not (Test-Path $rescate)) {
        Write-Log 'No encuentro Rescate.ps1 al lado de Booster.ps1. Baja el repo completo.' 'err'
        return
    }
    Write-Log 'Abriendo Booster Rescate...' 'title'
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rescate`""
})

# ================= PÁGINA DIAGNÓSTICO =================
# Dos cosas: (1) auditar los ajustes que de verdad mueven la aguja (Hz del
# monitor, XMP, plan de energía, etc.) y (2) MEDIR el ruido de fondo de la
# PC antes y después, para que cada tweak se justifique con números.
# Todo es de solo lectura: acá no se cambia nada.
function Get-Diagnostico {
    $r = New-Object System.Collections.ArrayList
    function Add-Chequeo($chequeo, $estado, $detalle) {
        [void]$r.Add([pscustomobject]@{ Chequeo = $chequeo; Estado = $estado; Detalle = $detalle })
    }

    # Monitor: ¿está corriendo a los Hz que da?
    try {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentRefreshRate })) {
            $res = "$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution) a $($v.CurrentRefreshRate) Hz"
            if ($v.MaxRefreshRate -and $v.CurrentRefreshRate -lt ($v.MaxRefreshRate - 1)) {
                Add-Chequeo 'Monitor' 'REVISAR' "$res, pero según Windows da hasta $($v.MaxRefreshRate) Hz. Subilo en Configuración > Pantalla > Pantalla avanzada."
            } else {
                Add-Chequeo 'Monitor' 'OK' "$res ($($v.Name))"
            }
        }
    } catch {}

    # RAM: XMP/EXPO y doble canal
    try {
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $lentos = @($dimms | Where-Object { $_.Speed -and $_.ConfiguredClockSpeed -and $_.ConfiguredClockSpeed -lt $_.Speed })
        $det = ($dimms | ForEach-Object { '{0} GB a {1} MHz' -f [Math]::Round($_.Capacity / 1GB), $_.ConfiguredClockSpeed }) -join ' + '
        if ($lentos.Count -gt 0) {
            Add-Chequeo 'RAM (XMP/EXPO)' 'REVISAR' "$det, pero los módulos dan $($lentos[0].Speed) MHz: activá XMP/EXPO en la BIOS."
        } else {
            Add-Chequeo 'RAM (XMP/EXPO)' 'OK' $det
        }
        if ($dimms.Count -eq 1) { Add-Chequeo 'RAM (canales)' 'REVISAR' 'Un solo módulo = canal simple. Con dos módulos los juegos ganan FPS mínimos.' }
    } catch {}

    # Plan de energía
    $plan = Get-ActivePowerPlan
    if ($plan -and @('381b4222-f694-41f0-9685-ff5bb260df2e', 'a1841308-3541-4fab-bc81-f71556f20b4a') -contains $plan.ToLower()) {
        Add-Chequeo 'Plan de energía' 'REVISAR' 'Equilibrado/Economizador: estaciona núcleos. El modo gaming lo pasa a Alto rendimiento solo.'
    } elseif ($plan) {
        Add-Chequeo 'Plan de energía' 'OK' 'Plan de rendimiento activo.'
    }

    # Ajustes de Windows para juegos
    $hags = Get-RegValueOrNull 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($hags -eq 2)     { Add-Chequeo 'Programación de GPU por hardware' 'OK' 'Activa.' }
    elseif ($hags -eq 1) { Add-Chequeo 'Programación de GPU por hardware' 'INFO' 'Apagada. Probá prenderla en Configuración > Pantalla > Gráficos y medí.' }

    if ((Get-RegValueOrNull 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 0) {
        Add-Chequeo 'Modo de juego de Windows' 'REVISAR' 'Apagado. Prendelo en Configuración > Juegos > Modo de juego.'
    } else {
        Add-Chequeo 'Modo de juego de Windows' 'OK' 'Activo.'
    }

    if ((Get-RegValueOrNull 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0) {
        Add-Chequeo 'Grabación de fondo (GameDVR)' 'OK' 'Apagada.'
    } else {
        Add-Chequeo 'Grabación de fondo (GameDVR)' 'REVISAR' "Windows graba gameplay de fondo. 'Optimizar PC' (página Pro) la apaga con backup."
    }

    if ([string](Get-RegValueOrNull 'HKCU:\Control Panel\Mouse' 'MouseSpeed') -eq '0') {
        Add-Chequeo 'Aceleración del mouse' 'OK' 'Apagada.'
    } else {
        Add-Chequeo 'Aceleración del mouse' 'REVISAR' "Prendida. Apagala en Panel de control > Mouse > Opciones de puntero > 'Mejorar la precisión del puntero'."
    }

    # Seguridad basada en virtualización: se informa, no se toca
    if ((Get-RegValueOrNull 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled') -eq 1) {
        Add-Chequeo 'Integridad de memoria (VBS)' 'INFO' 'Activa: suele costar algunos FPS. Es un ajuste de seguridad y es decisión tuya; Booster no lo toca.'
    }

    # CPU híbrido
    if ($script:CpuHibrido) {
        $build = [Environment]::OSVersion.Version.Build
        $txt = "$($script:CpuTopo[2]) núcleos P + $($script:CpuTopo[3]) núcleos E. "
        if ($build -lt 22000) {
            Add-Chequeo 'CPU híbrido' 'INFO' ($txt + "Windows 10 no reparte bien entre P y E: probá el toggle 'Solo P-cores' con el juego abierto y compará FPS.")
        } else {
            Add-Chequeo 'CPU híbrido' 'INFO' ($txt + "Windows 11 ya los reparte; 'Solo P-cores' es opcional, probalo por juego.")
        }
    }

    # Notebook: a batería Windows y el fabricante limitan CPU y GPU
    switch (Get-Alimentacion) {
        'bateria'   { Add-Chequeo 'Alimentación' 'REVISAR' 'Estás a batería: la notebook limita el rendimiento y el modo gaming no cambia el plan de energía. Enchufá el cargador para jugar.' }
        'enchufada' { Add-Chequeo 'Alimentación' 'OK' 'Notebook enchufada.' }
    }

    # Disco del sistema
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        $pct = [Math]::Round($d.FreeSpace / $d.Size * 100)
        $txt = '{0} {1:N0} GB libres ({2}%)' -f $env:SystemDrive, ($d.FreeSpace / 1GB), $pct
        if ($pct -lt 15) { Add-Chequeo 'Disco del sistema' 'REVISAR' "$txt. Con poco espacio el SSD rinde peor: probá 'Limpiar basura'." }
        else             { Add-Chequeo 'Disco del sistema' 'OK' $txt }
    } catch {}

    # Lo que Booster dejó pausado y los servers blindados
    $pausados = @((Get-State).servicios | Where-Object { $_ } | Where-Object {
        $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
        $s -and $s.Status -ne 'Running'
    })
    if ($pausados.Count -gt 0) {
        Add-Chequeo 'Servicios pausados por Booster' 'INFO' ("{0} sin restaurar: {1}. 'Restaurar todo' los levanta." -f $pausados.Count, ($pausados -join ', '))
    }
    $blindados = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-Servidor $_.Name } | ForEach-Object { $_.Name } | Select-Object -Unique)
    if ($blindados.Count -gt 0) {
        Add-Chequeo 'Servers blindados' 'OK' ("Corriendo y protegidos: {0}. (Lista 'servidores' del config.json)" -f ($blindados -join ', '))
    } else {
        Add-Chequeo 'Servers blindados' 'OK' "Ninguno corriendo ahora. (Lista 'servidores' del config.json)"
    }
    return $r
}

# --- Medición del ruido de fondo (antes / después) ---
$script:Metricas = @(
    @{ K = 'cpuFondoPct'; N = 'CPU ocupada por el fondo';      F = '{0:N2} %';  MenorMejor = $true  },
    @{ K = 'dpcPct';      N = 'Tiempo en DPC (drivers)';       F = '{0:N2} %';  MenorMejor = $true  },
    @{ K = 'irqPct';      N = 'Tiempo en interrupciones';      F = '{0:N2} %';  MenorMejor = $true  },
    @{ K = 'ctxSeg';      N = 'Cambios de contexto por seg';   F = '{0:N0}';    MenorMejor = $true  },
    @{ K = 'procesos';    N = 'Procesos corriendo';            F = '{0:N0}';    MenorMejor = $true  },
    @{ K = 'servicios';   N = 'Servicios corriendo';           F = '{0:N0}';    MenorMejor = $true  },
    @{ K = 'ramLibreMB';  N = 'RAM libre';                     F = '{0:N0} MB'; MenorMejor = $false },
    @{ K = 'pingMs';      N = 'Ping promedio (1.1.1.1)';       F = '{0:N1} ms'; MenorMejor = $true  },
    @{ K = 'jitterMs';    N = 'Jitter';                        F = '{0:N1} ms'; MenorMejor = $true  },
    @{ K = 'perdidaPct';  N = 'Paquetes perdidos';             F = '{0:N0} %';  MenorMejor = $true  }
)

function Get-RawPerf {
    # Contadores crudos de WMI (no dependen del idioma de Windows). Con dos
    # muestras se saca el promedio exacto del intervalo sin medir en el medio.
    $c = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    $s = Get-CimInstance Win32_PerfRawData_PerfOS_System -ErrorAction Stop
    [pscustomobject]@{
        T    = [double]$c.Timestamp_Sys100NS
        Idle = [double]$c.PercentProcessorTime
        Dpc  = [double]$c.PercentDPCTime
        Irq  = [double]$c.PercentInterruptTime
        Ctx  = [double]$s.ContextSwitchesPersec
    }
}

function Get-Mediciones {
    $vacio = [pscustomobject]@{ base = $null; ultima = $null }
    if (-not (Test-Path $MedicionesPath)) { return $vacio }
    try {
        $m = Get-Content $MedicionesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in 'base', 'ultima') {
            if ($m.PSObject.Properties.Name -notcontains $k) { $m | Add-Member -NotePropertyName $k -NotePropertyValue $null }
        }
        return $m
    } catch { return $vacio }
}

function Invoke-Medicion([string]$modo) {
    # $modo: 'base' (guarda el punto de partida) o 'comparar' (mide y compara con la base)
    if ($script:Midiendo) { return }
    if ($script:Sigilo) {
        Write-Log 'Hay un juego abierto: la medición es del ruido de fondo, hacela con el juego cerrado.' 'warn'
        return
    }
    $med = Get-Mediciones
    if ($modo -eq 'comparar' -and -not $med.base) {
        Write-Log "Primero tocá 'Medir base' (antes de aplicar el modo gaming)." 'warn'
        return
    }
    $script:Midiendo = $true
    $form.Cursor = 'WaitCursor'
    try {
        Write-Log 'Midiendo 15 segundos el ruido de fondo de la PC: no toques nada...' 'title'
        $a = Get-RawPerf
        $pings = @(); $perdidos = 0
        $pg = New-Object System.Net.NetworkInformation.Ping
        for ($i = 0; $i -lt 15; $i++) {
            $t0 = Get-Date
            try {
                $rp = $pg.Send('1.1.1.1', 900)
                if ($rp.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $pings += [int]$rp.RoundtripTime } else { $perdidos++ }
            } catch { $perdidos++ }
            while (((Get-Date) - $t0).TotalMilliseconds -lt 1000) {
                Start-Sleep -Milliseconds 50
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        $pg.Dispose()
        $b  = Get-RawPerf
        $dt = [Math]::Max(1, $b.T - $a.T)
        $jit = 0.0
        for ($i = 1; $i -lt $pings.Count; $i++) { $jit += [Math]::Abs($pings[$i] - $pings[$i - 1]) }
        if ($pings.Count -gt 1) { $jit = $jit / ($pings.Count - 1) }

        $m = [ordered]@{
            fecha       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            cpuFondoPct = [Math]::Round([Math]::Max(0, (1 - ($b.Idle - $a.Idle) / $dt) * 100), 2)
            dpcPct      = [Math]::Round(($b.Dpc - $a.Dpc) / $dt * 100, 2)
            irqPct      = [Math]::Round(($b.Irq - $a.Irq) / $dt * 100, 2)
            ctxSeg      = [Math]::Round(($b.Ctx - $a.Ctx) / ($dt / 10000000))
            procesos    = @(Get-Process).Count
            servicios   = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count
            ramLibreMB  = ([BoosterRam]::Query())[1]
            pingMs      = if ($pings.Count -gt 0) { [Math]::Round(($pings | Measure-Object -Average).Average, 1) } else { 0 }
            jitterMs    = [Math]::Round($jit, 1)
            perdidaPct  = [Math]::Round($perdidos / 15 * 100)
        }
        if ($modo -eq 'base') { $med.base = $m; $med.ultima = $null } else { $med.ultima = $m }
        ConvertTo-Json -InputObject $med -Depth 4 | Set-Content $MedicionesPath -Encoding UTF8

        if ($modo -eq 'base') {
            Write-Log ("Base guardada: fondo {0:N2}% de CPU, {1:N0} procesos, {2:N0} servicios, ping {3:N1} ms. Ahora aplicá el modo gaming y tocá 'Medir y comparar'." -f $m.cpuFondoPct, $m.procesos, $m.servicios, $m.pingMs) 'ok'
        } else {
            Write-Log 'Comparación lista: mirá la tabla de la página Diagnóstico.' 'ok'
        }
    } catch {
        Write-Log "No se pudo medir: $($_.Exception.Message)" 'err'
    } finally {
        $script:Midiendo = $false
        $form.Cursor = 'Default'
    }
    Invoke-Diagnostico -Silencioso
}

function Invoke-Diagnostico([switch]$Silencioso) {
    $lvDiag.BeginUpdate()
    $lvDiag.Items.Clear()
    $revisar = 0
    foreach ($c in (Get-Diagnostico)) {
        $item = New-Object System.Windows.Forms.ListViewItem($c.Chequeo)
        [void]$item.SubItems.Add($c.Estado)
        [void]$item.SubItems.Add($c.Detalle)
        $item.ToolTipText = $c.Detalle
        $item.ForeColor = switch ($c.Estado) { 'OK' { $colGreen } 'REVISAR' { $colYellow } default { $colText } }
        if ($c.Estado -eq 'REVISAR') { $revisar++ }
        [void]$lvDiag.Items.Add($item)
    }

    # Filas de medición: base sola, o base -> después con veredicto
    $med = Get-Mediciones
    if ($med.base) {
        foreach ($mt in $script:Metricas) {
            $va = [double]$med.base.($mt.K)
            $item = New-Object System.Windows.Forms.ListViewItem('MEDICIÓN · ' + $mt.N)
            if ($med.ultima) {
                $vb = [double]$med.ultima.($mt.K)
                [void]$item.SubItems.Add((($mt.F -f $va) + '  →  ' + ($mt.F -f $vb)))
                $dif = $vb - $va
                # Cambios de menos del 5% (o ínfimos) son ruido de medición, no mejora
                $piso = switch ($mt.K) {
                    'cpuFondoPct' { 0.5 } 'dpcPct' { 0.1 } 'irqPct' { 0.1 } 'procesos' { 2 } 'servicios' { 1 }
                    'ramLibreMB' { 200 } 'pingMs' { 1 } 'jitterMs' { 1 } 'perdidaPct' { 5 } default { 0.05 }
                }
                $ruido = [Math]::Max([Math]::Abs($va) * 0.05, $piso)
                if ([Math]::Abs($dif) -le $ruido) {
                    [void]$item.SubItems.Add('Igual (dentro del ruido de medición)')
                    $item.ForeColor = $colDim
                } else {
                    $mejor = if ($mt.MenorMejor) { $dif -lt 0 } else { $dif -gt 0 }
                    $pct = if ($va -ne 0) { ' ({0:+0;-0}%)' -f ($dif / $va * 100) } else { '' }
                    [void]$item.SubItems.Add($(if ($mejor) { 'MEJOR' } else { 'PEOR' }) + $pct)
                    $item.ForeColor = if ($mejor) { $colGreen } else { $colRed }
                }
            } else {
                [void]$item.SubItems.Add(($mt.F -f $va))
                [void]$item.SubItems.Add("Base del $($med.base.fecha). Aplicá el modo gaming y tocá 'Medir y comparar'.")
                $item.ForeColor = $colBlue
            }
            [void]$lvDiag.Items.Add($item)
        }
    }
    $lvDiag.EndUpdate()
    if (-not $Silencioso) {
        Write-Log $(if ($revisar -gt 0) { "Diagnóstico: $revisar punto(s) para revisar (en amarillo)." } else { 'Diagnóstico: todo lo que se puede chequear desde acá está en orden.' }) $(if ($revisar -gt 0) { 'warn' } else { 'ok' })
    }
}

$lblDiag = New-Object System.Windows.Forms.Label
$lblDiag.Text      = 'DIAGNÓSTICO — solo lectura: acá no se cambia nada'
$lblDiag.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblDiag.ForeColor = $colDim
$lblDiag.Location  = New-Object System.Drawing.Point(0, 0)
$lblDiag.AutoSize  = $true
$pageDiag.Controls.Add($lblDiag)

$lvDiag = New-Object System.Windows.Forms.ListView
$lvDiag.Location         = New-Object System.Drawing.Point(0, 22)
$lvDiag.Size             = New-Object System.Drawing.Size(1116, 400)
$lvDiag.View             = 'Details'
$lvDiag.FullRowSelect    = $true
$lvDiag.ShowItemToolTips = $true
$lvDiag.BackColor        = $colPanel
$lvDiag.ForeColor        = $colText
$lvDiag.BorderStyle      = 'None'
[void]$lvDiag.Columns.Add('Chequeo', 270)
[void]$lvDiag.Columns.Add('Estado', 230)
[void]$lvDiag.Columns.Add('Detalle', 596)
Set-DarkList $lvDiag
$pageDiag.Controls.Add($lvDiag)

$btnDiag = New-Btn 'Analizar de nuevo' 0 438 170 40 $colSurface $colText $pageDiag
$btnDiag.Add_Click({ Invoke-Diagnostico })

$btnMedBase = New-Btn 'Medir base (15 s)' 178 438 170 40 $colBlue $colDark $pageDiag
$btnMedBase.Add_Click({ Invoke-Medicion 'base' })

$btnMedCmp = New-Btn 'Medir y comparar (15 s)' 356 438 200 40 $colAccent $colDark $pageDiag
$btnMedCmp.Add_Click({ Invoke-Medicion 'comparar' })

$lblDiagHint = New-Object System.Windows.Forms.Label
$lblDiagHint.Text      = "Medí la base, aplicá el modo gaming y medí de nuevo (sin juego abierto).`nMide el ruido de fondo que le roba al juego; menos del 5% de diferencia es ruido."
$lblDiagHint.ForeColor = $colDim
$lblDiagHint.Location  = New-Object System.Drawing.Point(572, 438)
$lblDiagHint.Size      = New-Object System.Drawing.Size(544, 44)
$pageDiag.Controls.Add($lblDiagHint)

$btnTimerGlobal = New-ProRow 'Timer global (Win11)' 492 $colSurface $colText "Solo Windows 11: hace que el toggle 'Timer 0,5 ms' le llegue al juego y no solo a Booster (clave GlobalTimerResolutionRequests, con backup; pide reiniciar). En Windows 10 no existe. Se deshace con 'Revertir tweaks'."
$btnTimerGlobal.Add_Click({ Enable-TimerGlobal })

# ----- Registro (compartido entre páginas) -----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'REGISTRO'
$lblLog.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblLog.ForeColor = $colDim
$lblLog.Location  = New-Object System.Drawing.Point(24, 678)
$lblLog.AutoSize  = $true
$form.Controls.Add($lblLog)

# El registro vive dentro de una tarjeta redondeada
$logCard = New-Object System.Windows.Forms.Panel
$logCard.Location  = New-Object System.Drawing.Point(24, 700)
$logCard.Size      = New-Object System.Drawing.Size(1116, 100)
$logCard.BackColor = $colPanel
Set-Rounded $logCard 10
$form.Controls.Add($logCard)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(12, 8)
$logBox.Size        = New-Object System.Drawing.Size(1098, 84)
$logBox.ReadOnly    = $true
$logBox.BackColor   = $colPanel
$logBox.ForeColor   = $colText
$logBox.BorderStyle = 'None'
$logBox.Font        = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Add_HandleCreated({ [BoosterUi]::DarkScroll($this.Handle) })
$logCard.Controls.Add($logBox)

function Write-Log([string]$msg, [string]$kind = 'info') {
    $color = switch ($kind) {
        'ok'    { $colGreen }
        'err'   { $colRed }
        'warn'  { $colYellow }
        'title' { $colAccent }
        default { $colDim }
    }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionColor  = $color
    $logBox.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + "`r`n")
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ----- Timer del dashboard: muestrea RAM 1/seg y anima el gráfico -----
function Update-Dashboard {
    $q = [BoosterRam]::Query()
    $script:TotalRamMB = $q[0]
    $usada = $q[0] - $q[1]
    [void]$script:RamHist.Add([pscustomobject]@{ Tick = $script:TickNum; UsedMB = $usada })
    while ($script:RamHist.Count -gt $script:HistCap) { $script:RamHist.RemoveAt(0) }

    # Ping por segundo, ASÍNCRONO: se lanza en un tick y se lee en el siguiente,
    # así la interfaz nunca se traba esperando la red. En modo sigilo (juego
    # abierto) directamente no se pinguea.
    if (-not $script:Sigilo) {
        if ($script:PingTask -and $script:PingTask.IsCompleted) {
            $ms = 250
            try {
                $reply = $script:PingTask.Result
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ms = [int]$reply.RoundtripTime }
            } catch {}
            $script:PingTask = $null
            [void]$script:PingHist.Add([pscustomobject]@{ Tick = $script:TickNum; Ms = $ms })
            while ($script:PingHist.Count -gt $script:HistCap) { $script:PingHist.RemoveAt(0) }
        }
        if (-not $script:PingTask) {
            try { $script:PingTask = $script:Pinger.SendPingAsync('1.1.1.1', 250) } catch { $script:PingTask = $null }
        }
    }

    $lblCardUsada.Text = '{0:N1} GB' -f ($usada / 1024)
    $lblCardUsada.ForeColor = if ($q[2] -ge 85) { $colRed } elseif ($q[2] -ge 70) { $colYellow } else { $colAccent }
    $lblCardLibre.Text = '{0:N1} GB' -f ($q[1] / 1024)
    $lblCardPurga.Text = if ($script:PurgadoSesionMB -ge 1024) { '{0:N1} GB' -f ($script:PurgadoSesionMB / 1024) } else { '{0:N0} MB' -f $script:PurgadoSesionMB }

    # Auto-purga tipo ISLC: RAM libre bajo el umbral -> purga sola
    # (con enfriamiento de 2 minutos para no purgar en loop)
    if ($chkAutoPurga.Checked -and $q[1] -lt [long]$Config.autoPurgaLibreMB -and ($script:TickNum - $script:UltimaAutoPurga) -ge 120) {
        $script:UltimaAutoPurga = $script:TickNum
        Write-Log ("Auto-purga: RAM libre en {0:N0} MB (umbral {1:N0} MB)." -f $q[1], $Config.autoPurgaLibreMB) 'warn'
        Clear-StandbyMemory
    }

    # Solo se redibuja si de verdad se está mirando la página
    if ($pageRecursos.Visible -and $form.Visible -and $form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $chartPanel.Invalidate()
        $pingPanel.Invalidate()
    }
}

function Update-GpuStats {
    # nvidia-smi tarda ~100ms: se llama cada 5 segundos y sin ventana
    if (-not $script:GpuOk) { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'nvidia-smi'
        $psi.Arguments              = '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits'
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow         = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadLine()
        [void]$proc.WaitForExit(1500)
        if ($out) {
            $p = $out.Split(',')
            $lblCardGpu.Text  = ('{0}%  {1}°C' -f $p[0].Trim(), $p[3].Trim())
            $lblCardVram.Text = ('{0:N1}/{1:N1} GB' -f ([double]$p[1].Trim() / 1024), ([double]$p[2].Trim() / 1024))
        }
    } catch { $script:GpuOk = $false }
}

# ----- Vigía de juegos + modo sigilo -----
# Con un juego abierto Booster se calla: nada de ping, nada de nvidia-smi,
# nada de recorrer procesos, y el timer pasa de 1 a 5 segundos. Lo único
# que sigue es leer la RAM (una llamada nativa) para la auto-purga.
function Test-PidVivo([int]$id) {
    # No abre un handle al proceso: anda aunque el anticheat lo proteja
    try { [void][System.Diagnostics.Process]::GetProcessById($id); return $true } catch { return $false }
}

function Enter-Sigilo($juegos) {
    $script:JuegoPids = @($juegos | ForEach-Object { $_.Id })
    $nombre = $juegos[0].Name
    if (-not $script:Sigilo) {
        $script:Sigilo = $true
        $script:PingTask = $null
        $timerUI.Interval = 5000
        $lblSub.Text      = "Modo sigilo: $nombre en curso"
        $lblSub.ForeColor = $colGreen
        Write-Log "Juego detectado: $nombre. Modo sigilo: dejo de medir ping/GPU y de recorrer procesos hasta que cierres." 'title'

        if ($chkAuto.Checked -and -not $script:BoostEnCurso) {
            # Perfil por juego: qué apps conservar para este juego puntual
            $perfil = @($Config.perfiles) | Where-Object { $_ -and $nombre -like $_.juego } | Select-Object -First 1
            $conservar = if ($perfil) { @($perfil.conservar | Where-Object { $_ }) } else { @() }
            if ($conservar.Count -gt 0) { Write-Log "Perfil de ${nombre}: conserva $($conservar -join ', ')" 'info' }
            Invoke-GamingMode -Silencioso -Conservar $conservar
            return
        }
    }
    if ($chkAuto.Checked) {
        # Proceso nuevo del mismo juego (el launcher abrió el ejecutable real)
        Set-GamePriority
    } else {
        # Sin auto-gaming: solo la afinidad, si está pedida
        foreach ($p in $juegos) {
            if (Test-QuierePCores $p.Name) { Set-GameAffinity $p $true }
        }
    }
}

function Exit-Sigilo {
    $script:Sigilo    = $false
    $script:JuegoPids = @()
    $timerUI.Interval = 1000
    $lblSub.Text      = 'Liberá tu PC después del trabajo'
    $lblSub.ForeColor = $colDim
    Write-Log "Juego cerrado: vuelvo al monitoreo normal. ('Restaurar todo' o Modo trabajo reactivan lo pausado.)" 'title'
}

function Update-GameWatch {
    if ($script:BoostEnCurso) { return }
    if ($script:Sigilo) {
        $script:JuegoPids = @($script:JuegoPids | Where-Object { Test-PidVivo $_ })
        if ($script:JuegoPids.Count -eq 0) { Exit-Sigilo }
    }
    $hayNuevo = $false
    if ($script:WatchOk) {
        # Camino barato: solo se mira lo que el evento de WMI avisó que arrancó
        foreach ($n in [BoosterWatch]::Drain()) {
            if (Test-InList $n $Config.juegos) { $hayNuevo = $true }
        }
    } elseif (-not $script:Sigilo -and ($script:TickNum % 5 -eq 0)) {
        # Respaldo si el evento de WMI no está disponible: sondeo cada 5 s
        $hayNuevo = $true
    }
    if ($hayNuevo) {
        $juegos = Get-GameProcesses
        if ($juegos.Count -gt 0) { Enter-Sigilo $juegos }
    }
}

function Test-BoosterUpdate {
    # Compara la versión local contra el repo de GitHub (una vez, al abrir)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $head = $wc.DownloadString('https://raw.githubusercontent.com/ValeenMar/booster/master/Booster.ps1')
        if ($head -match 'BOOSTER v(\d+)') {
            $remota = [int]$Matches[1]
            if ($remota -gt $script:BoosterVersion) {
                Write-Log "Hay una versión nueva de Booster (v$remota, tenés la v$($script:BoosterVersion)): hacé git pull o bajá el ZIP del repo." 'warn'
            }
        }
    } catch {}
}

$timerUI = New-Object System.Windows.Forms.Timer
$timerUI.Interval = 1000
$timerUI.Add_Tick({
    # TickNum cuenta segundos: en sigilo el timer va cada 5 s y avanza de a 5
    $script:TickNum += [int]($timerUI.Interval / 1000)
    Update-Dashboard
    Update-GameWatch
    if (-not $script:Sigilo) {
        if ($script:TickNum % 5 -eq 2) { Update-GpuStats }
        if ($script:TickNum -eq 3)     { Test-BoosterUpdate }
    }
})

# ----- Bandeja del sistema -----
# Minimizar manda a Booster al lado del reloj:
# el auto-gaming y la auto-purga siguen laburando en segundo plano.
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon    = $script:BoosterIcon
$notifyIcon.Text    = 'Booster'
$notifyIcon.Visible = $true

function Show-FromTray {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Mostrar Booster', $null, { Show-FromTray })
[void]$trayMenu.Items.Add('Modo gaming', $null, { Show-FromTray; Invoke-GamingMode })
[void]$trayMenu.Items.Add('Purgar RAM caché', $null, { Clear-StandbyMemory })
[void]$trayMenu.Items.Add('Restaurar todo', $null, { Restore-Services })
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add('Salir de Booster', $null, { $script:SalirDeVerdad = $true; $form.Close() })
$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Add_DoubleClick({ Show-FromTray })

$script:BalloonMostrado = $false
$script:SalirDeVerdad   = $false

function Hide-ToTray {
    $form.Hide()
    if (-not $script:BalloonMostrado) {
        $script:BalloonMostrado = $true
        $notifyIcon.ShowBalloonTip(2500, 'Booster', 'Sigo acá abajo, en los íconos ocultos: auto-gaming y auto-purga quedan activos. Doble clic para volver; clic derecho > Salir para cerrarme.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# Minimizar manda a la bandeja...
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { Hide-ToTray }
})

# ...y la X también (salvo 'cerrarALaBandeja: false' en el config). Para cerrar
# de verdad: clic derecho en el ícono de la bandeja > Salir de Booster.
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:SalirDeVerdad -and $Config.cerrarALaBandeja -and
        $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-ToTray
    }
})

# --- Arranque --------------------------------------------------
$form.Add_Shown({
    Show-Page 'recursos'
    Update-Dashboard
    Update-GpuStats
    $timerUI.Start()
    Write-Log 'Booster v9 listo. Minimizá y quedo en la bandeja, al lado del reloj, laburando solo.' 'title'

    # Vigía de juegos por evento (sin sondeo); si no está, se sondea cada 5 s
    $script:WatchOk = $false
    if ($script:WatchDisponible) { try { $script:WatchOk = [BoosterWatch]::Start() } catch {} }
    if (-not $script:WatchOk) { Write-Log 'Aviso: no pude engancharme a los eventos de procesos; detecto juegos sondeando cada 5 s.' 'warn' }
    if ($script:CpuHibrido) {
        Write-Log ("CPU híbrido: {0} núcleos P + {1} núcleos E. El toggle 'Solo P-cores' fija los juegos a los P." -f $script:CpuTopo[2], $script:CpuTopo[3]) 'info'
    }
    $blindados = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-Servidor $_.Name } | ForEach-Object { $_.Name } | Select-Object -Unique)
    if ($blindados.Count -gt 0) { Write-Log "Servers blindados corriendo (no se tocan): $($blindados -join ', ')" 'info' }

    if ((Get-Alimentacion) -eq 'bateria') { Write-Log 'Notebook a batería: enchufá el cargador para rendir al máximo.' 'warn' }
    if (-not $script:GpuOk) { $lblCardGpu.Text = 'Solo NVIDIA'; $lblCardVram.Text = 'Solo NVIDIA' }

    # Toggles que el config pide prendidos de entrada
    if ($Config.soloPCores -and $script:CpuHibrido) { $chkPCores.Checked = $true }
    if ($Config.autoGaming) { $chkAuto.Checked = $true }
    if ($Config.timer05)    { $chkTimer.Checked = $true }

    Refresh-ServiceList
    Refresh-ProcessList
    Invoke-Diagnostico -Silencioso

    # Si ya hay un juego abierto al arrancar, sigilo de una
    $yaJugando = Get-GameProcesses
    if ($yaJugando.Count -gt 0) { Enter-Sigilo $yaJugando }
})

$form.Add_FormClosed({
    $timerUI.Stop()
    try { [BoosterWatch]::Stop() } catch {}
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
})

# Con toda la ventana armada, se la lleva a la escala de esta PC
Initialize-UiScale
Invoke-UiScale $form

# Application.Run y no ShowDialog: una ventana modal se CIERRA al ocultarla,
# y por eso antes Booster moría al minimizarlo a la bandeja.
[System.Windows.Forms.Application]::Run($form)
if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {}; $script:Mutex.Dispose() }
