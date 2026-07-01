# ============================================================
#  BOOSTER v6 - Optimizador gaming para despues del trabajo
#  - Listas con comodines (Adobe* cierra todo lo de Adobe)
#  - Barrido de procesos de fondo sin ventana
#  - Pausa servicios de Windows Y de terceros (updaters, etc.)
#  - Protege anticheats, drivers de GPU/audio/perifericos
#  - Modulo de red: menos latencia (Nagle, throttling, DNS)
#  - Tweaks persistentes con backup: GameDVR off y ahorro de
#    energia de NIC/USB off; un boton para revertir todo
#  - Plan de energia Alto rendimiento en modo gaming
#  - Timer del sistema a 0.5 ms mientras Booster este abierto
#  - Gestor de apps de inicio (misma mecanica que el Adm. de tareas)
#  - Purga de memoria standby estilo ISLC
#  - Auto-modo gaming: detecta juegos y se activa solo (silencioso)
#  - Dashboard Catppuccin Mocha con grafico de RAM en tiempo real:
#    las purgas se marcan en verde y se ve el bajon en vivo
# ============================================================
#Requires -Version 5.1

# --- Auto-elevación (necesaria para pausar servicios) -------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# API nativa para el timer de alta precisión (estilo TimerResolution/ISLC)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BoosterTimer {
    [DllImport("ntdll.dll")]
    public static extern int NtQueryTimerResolution(out uint min, out uint max, out uint current);
    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(uint desired, bool set, out uint current);
}
"@

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

# --- Configuración -------------------------------------------
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
    umbralRamMB         = 100
}

if (Test-Path $ConfigPath) {
    try {
        $script:Config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show("config.json tiene un error de formato, se usa la configuración por defecto.`n$($_.Exception.Message)", 'Booster', 'OK', 'Warning') | Out-Null
        $script:Config = [pscustomobject]$defaultConfig
    }
} else {
    $defaultConfig | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
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
            $grupos[$p.Name] = [pscustomobject]@{ Name = $p.Name; Count = 0; RamMB = 0.0; CpuMs = 0.0; TieneVentana = $false }
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
        -not (Test-InList $_.Name $Config.protegidos)
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
        -not (Test-InList $_.Name $Config.protegidos) -and
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
        -not (Test-InList $_.Name $Config.serviciosProtegidos) -and
        -not (Test-InList $_.DisplayName $Config.serviciosProtegidos)
    }
}

function Close-ProcessByName([string]$name) {
    if (Test-InList $name $Config.protegidos) {
        Write-Log "Ignorado (protegido): $name" 'warn'
        return
    }
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $ram = [Math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
    Write-Log "Cerrado: $name (~$ram MB)" 'ok'
}

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
    if ($tweaks.PSObject.Properties.Name -notcontains 'ahorroDispositivos') {
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

function Enable-HighPerformance {
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

function Set-TimerResolution([bool]$activar) {
    # El timer por defecto de Windows es de 15.6 ms; subirlo a 0.5 ms
    # mejora el frame pacing. Dura mientras el proceso viva: al cerrar
    # Booster, Windows lo libera solo.
    $min = [uint32]0; $max = [uint32]0; $cur = [uint32]0
    [void][BoosterTimer]::NtQueryTimerResolution([ref]$min, [ref]$max, [ref]$cur)
    $out = [uint32]0
    if ($activar) {
        [void][BoosterTimer]::NtSetTimerResolution($max, $true, [ref]$out)
        Write-Log ("Timer del sistema: {0:N2} ms -> {1:N2} ms (dura mientras Booster esté abierto)." -f ($cur / 10000), ($out / 10000)) 'ok'
    } else {
        [void][BoosterTimer]::NtSetTimerResolution($max, $false, [ref]$out)
        Write-Log 'Timer del sistema liberado.' 'info'
    }
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
    $lbl.Text     = "Apps abiertas y procesos de fondo detectados.`nDestildá lo que quieras dejar corriendo:"
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
        $item.Checked = $true
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

    if ($dlg.ShowDialog($form) -eq 'OK') {
        return @($lv.CheckedItems | ForEach-Object { $_.Text })
    }
    return @()
}

function Invoke-GamingMode([switch]$Silencioso) {
    $script:BoostEnCurso = $true
    Write-Log $(if ($Silencioso) { '=== MODO GAMING AUTOMÁTICO (silencioso) ===' } else { '=== MODO GAMING ACTIVADO ===' }) 'title'
    $ramAntes = Get-FreeRamMB

    # 1) Cierre automático de la lista segura (con comodines)
    $auto = @(Get-RunningMatches $Config.cerrarSiempre)
    foreach ($g in $auto) { Close-ProcessByName $g.Name }
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
            foreach ($name in $elegidos) { Close-ProcessByName $name }
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

    # 6) Plan de energía Alto rendimiento y timer de 0.5 ms
    Enable-HighPerformance
    if (-not $chkTimer.Checked) { $chkTimer.Checked = $true }

    # 7) Purgar la memoria standby (los procesos recién cerrados dejan caché)
    Start-Sleep -Milliseconds 1500
    Clear-StandbyMemory

    $ramDespues = Get-FreeRamMB
    $ganancia = $ramDespues - $ramAntes
    Write-Log ("=== LISTO. RAM libre: {0:N0} MB -> {1:N0} MB ({2}{3:N0} MB) ===" -f $ramAntes, $ramDespues, $(if ($ganancia -ge 0) { '+' } else { '' }), $ganancia) 'title'

    Refresh-ServiceList
    Refresh-ProcessList
    $script:BoostEnCurso = $false
}

# --- GUI v6: dashboard con gráfico de RAM en vivo ---------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Booster - Optimizador gaming'
$form.Size            = New-Object System.Drawing.Size(1180, 850)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $colBg
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.5)

function Set-Rounded($ctl, [int]$r) {
    # Esquinas redondeadas via Region (GraphicsPath de 4 arcos)
    $d = $r * 2
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $d, $d, 180, 90)
    $gp.AddArc($ctl.Width - $d - 1, 0, $d, $d, 270, 90)
    $gp.AddArc($ctl.Width - $d - 1, $ctl.Height - $d - 1, $d, $d, 0, 90)
    $gp.AddArc(0, $ctl.Height - $d - 1, $d, $d, 90, 90)
    $gp.CloseFigure()
    $ctl.Region = New-Object System.Drawing.Region($gp)
}

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $bg, $fg) {
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
    Set-Rounded $b 8
    $form.Controls.Add($b)
    return $b
}

function New-Toggle([string]$text, [int]$x, [int]$y, [int]$w) {
    # Checkbox con pinta de pill/toggle: gris apagado, mauve encendido
    $t = New-Object System.Windows.Forms.CheckBox
    $t.Appearance = 'Button'
    $t.Text       = $text
    $t.Location   = New-Object System.Drawing.Point($x, $y)
    $t.Size       = New-Object System.Drawing.Size($w, 36)
    $t.TextAlign  = 'MiddleCenter'
    $t.FlatStyle  = 'Flat'
    $t.FlatAppearance.BorderSize = 0
    $t.FlatAppearance.CheckedBackColor = $colAccent
    $t.BackColor  = $colSurface
    $t.ForeColor  = $colText
    $t.Cursor     = 'Hand'
    $t.Add_CheckedChanged({ $this.ForeColor = if ($this.Checked) { $colDark } else { $colText } })
    Set-Rounded $t 18
    $form.Controls.Add($t)
    return $t
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

$chkTimer = New-Toggle 'Timer 0,5 ms' 668 20 138
$chkTimer.Add_CheckedChanged({ Set-TimerResolution $chkTimer.Checked })

$chkAuto = New-Toggle 'Auto-gaming' 816 20 138
$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) {
        Write-Log "Auto-gaming ON: al detectar un juego (lista 'juegos' del config) se activa el modo gaming solo, sin diálogos." 'info'
    } else {
        Write-Log 'Auto-gaming desactivado.' 'info'
    }
})

$btnGaming = New-Btn 'MODO GAMING' 966 14 174 48 $colAccent $colDark
$btnGaming.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$btnGaming.Add_Click({ Invoke-GamingMode })

# ----- Gráfico de RAM en vivo -----
$script:RamHist          = New-Object System.Collections.ArrayList
$script:PurgeMarks       = New-Object System.Collections.ArrayList
$script:TickNum          = 0
$script:HistCap          = 180      # 3 minutos de historia a 1 muestra/seg
$script:PurgadoSesionMB  = 0
$script:TotalRamMB       = ([BoosterRam]::Query())[0]
$script:JuegoDetectado   = $false
$script:BoostEnCurso     = $false

# Recursos GDI creados una sola vez (crearlos en cada Paint filtra handles)
$script:cFontCap  = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$script:cFontTiny = New-Object System.Drawing.Font('Segoe UI', 8)
$script:cFontBig  = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$script:cBrDim    = New-Object System.Drawing.SolidBrush($colDim)
$script:cBrAccent = New-Object System.Drawing.SolidBrush($colAccent)
$script:cBrGreen  = New-Object System.Drawing.SolidBrush($colGreen)
$script:cBrHalo   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, $colAccent))
$script:cPenGrid  = New-Object System.Drawing.Pen($colSurface, 1)
$script:cPenLine  = New-Object System.Drawing.Pen($colAccent, 2.2)
$script:cPenLine.LineJoin = 'Round'
$script:cPenMark  = New-Object System.Drawing.Pen($colGreen, 1.4)
$script:cPenMark.DashStyle = 'Dash'

$chartPanel = New-Object System.Windows.Forms.Panel
$chartPanel.Location  = New-Object System.Drawing.Point(24, 78)
$chartPanel.Size      = New-Object System.Drawing.Size(1116, 190)
$chartPanel.BackColor = $colPanel
Set-Rounded $chartPanel 12
# DoubleBuffered es protected en Panel: se activa por reflexión para que no parpadee
[System.Windows.Forms.Panel].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($chartPanel, $true, $null)
$form.Controls.Add($chartPanel)

$chartPanel.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $W = $sender.ClientSize.Width; $H = $sender.ClientSize.Height
    $padL = 18; $padR = 84; $padT = 42; $padB = 16
    $plotW = $W - $padL - $padR; $plotH = $H - $padT - $padB

    # Título + leyenda de purgas
    $g.DrawString('RAM EN VIVO', $cFontCap, $cBrDim, 18, 13)
    $g.DrawLine($cPenMark, 118, 21, 140, 21)
    $g.DrawString('purga', $cFontTiny, $cBrGreen, 144, 14)

    $hist = @($script:RamHist)
    if ($hist.Count -ge 1) {
        # Valor actual grande, arriba a la derecha
        $ultimo = $hist[$hist.Count - 1]
        $txt = ('{0:N1} GB' -f ($ultimo.UsedMB / 1024))
        $szB = $g.MeasureString($txt, $cFontBig)
        $g.DrawString($txt, $cFontBig, $cBrAccent, $W - 18 - $szB.Width, 6)
        $sub = ('en uso de {0:N0} GB' -f ($script:TotalRamMB / 1024))
        $szS = $g.MeasureString($sub, $cFontTiny)
        $g.DrawString($sub, $cFontTiny, $cBrDim, $W - 18 - $szS.Width, 6 + $szB.Height - 5)
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
    $area.AddLine($pts[$pts.Count - 1].X, $padT + $plotH, $pts[0].X, $padT + $plotH)
    $area.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF($padL, $padT, $plotW, $plotH + 1)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(105, $colAccent), [System.Drawing.Color]::FromArgb(0, $colAccent), 90.0)
    $g.FillPath($grad, $area)
    $grad.Dispose(); $area.Dispose()

    # Línea principal + punto vivo con halo
    $g.DrawLines($cPenLine, $pts.ToArray())
    $pu = $pts[$pts.Count - 1]
    $g.FillEllipse($cBrHalo, $pu.X - 7, $pu.Y - 7, 14, 14)
    $g.FillEllipse($cBrAccent, $pu.X - 3.5, $pu.Y - 3.5, 7, 7)

    # Marcas de purga: línea vertical verde + GB liberados
    foreach ($mk in @($script:PurgeMarks)) {
        if ($mk.Tick -lt $firstTick) { continue }
        $x = $padL + $plotW - ($lastTick - $mk.Tick) * $step
        $g.DrawLine($cPenMark, $x, $padT, $x, $padT + $plotH)
        $lbl = 'PURGA ' + $mk.Texto
        $sz = $g.MeasureString($lbl, $cFontTiny)
        $lx = [Math]::Max($padL, [Math]::Min($x - $sz.Width / 2, $padL + $plotW - $sz.Width))
        $g.DrawString($lbl, $cFontTiny, $cBrGreen, $lx, $padT - 16)
    }
})

# ----- Tarjetas de métricas -----
function New-Card([string]$caption, [int]$x, $valColor) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point($x, 280)
    $p.Size      = New-Object System.Drawing.Size(270, 66)
    $p.BackColor = $colPanel
    Set-Rounded $p 10
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text      = $caption
    $cap.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.25)
    $cap.ForeColor = $colDim
    $cap.Location  = New-Object System.Drawing.Point(14, 9)
    $cap.AutoSize  = $true
    $p.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text      = '—'
    $val.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $val.ForeColor = $valColor
    $val.Location  = New-Object System.Drawing.Point(12, 27)
    $val.AutoSize  = $true
    $p.Controls.Add($val)
    $form.Controls.Add($p)
    return $val
}

$lblCardUsada = New-Card 'RAM EN USO'            24  $colAccent
$lblCardLibre = New-Card 'RAM LIBRE'             306 $colGreen
$lblCardCarga = New-Card 'CARGA DE MEMORIA'      588 $colText
$lblCardPurga = New-Card 'PURGADO ESTA SESIÓN'   870 $colTeal

# ----- Panel de procesos -----
$lblProc = New-Object System.Windows.Forms.Label
$lblProc.Text      = 'PROCESOS TRAGONES'
$lblProc.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblProc.ForeColor = $colDim
$lblProc.Location  = New-Object System.Drawing.Point(24, 360)
$lblProc.AutoSize  = $true
$form.Controls.Add($lblProc)

$lvProc = New-Object System.Windows.Forms.ListView
$lvProc.Location      = New-Object System.Drawing.Point(24, 382)
$lvProc.Size          = New-Object System.Drawing.Size(690, 236)
$lvProc.View          = 'Details'
$lvProc.CheckBoxes    = $true
$lvProc.FullRowSelect = $true
$lvProc.BackColor     = $colPanel
$lvProc.ForeColor     = $colText
$lvProc.BorderStyle   = 'None'
[void]$lvProc.Columns.Add('Proceso', 250)
[void]$lvProc.Columns.Add('Instancias', 85)
[void]$lvProc.Columns.Add('RAM (MB)', 110)
[void]$lvProc.Columns.Add('CPU (%)', 85)
[void]$lvProc.Columns.Add('Fondo', 70)
$form.Controls.Add($lvProc)

function Refresh-ProcessList {
    $form.Cursor = 'WaitCursor'
    $lvProc.Items.Clear()
    foreach ($g in (Get-ProcessSnapshot)) {
        $item = New-Object System.Windows.Forms.ListViewItem($g.Name)
        [void]$item.SubItems.Add([string]$g.Count)
        [void]$item.SubItems.Add(([Math]::Round($g.RamMB)).ToString('N0'))
        [void]$item.SubItems.Add([string]$g.CpuPct)
        [void]$item.SubItems.Add($(if ($g.TieneVentana) { '' } else { 'Sí' }))
        if ($g.CpuPct -ge 15 -or $g.RamMB -ge 800) { $item.ForeColor = $colRed }
        [void]$lvProc.Items.Add($item)
    }
    $form.Cursor = 'Default'
}

# ----- Panel de servicios -----
$lblSvc = New-Object System.Windows.Forms.Label
$lblSvc.Text      = 'SERVICIOS (WINDOWS + TERCEROS)'
$lblSvc.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblSvc.ForeColor = $colDim
$lblSvc.Location  = New-Object System.Drawing.Point(730, 360)
$lblSvc.AutoSize  = $true
$form.Controls.Add($lblSvc)

$lvSvc = New-Object System.Windows.Forms.ListView
$lvSvc.Location      = New-Object System.Drawing.Point(730, 382)
$lvSvc.Size          = New-Object System.Drawing.Size(410, 236)
$lvSvc.View          = 'Details'
$lvSvc.CheckBoxes    = $true
$lvSvc.FullRowSelect = $true
$lvSvc.BackColor     = $colPanel
$lvSvc.ForeColor     = $colText
$lvSvc.BorderStyle   = 'None'
[void]$lvSvc.Columns.Add('Servicio', 205)
[void]$lvSvc.Columns.Add('Estado', 90)
[void]$lvSvc.Columns.Add('Origen', 80)
$form.Controls.Add($lvSvc)

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

# ----- Botonera -----
$btnRefresh = New-Btn 'Actualizar' 24 628 110 36 $colSurface $colText
$btnRefresh.Add_Click({ Refresh-ProcessList })

$btnKill = New-Btn 'Cerrar seleccionados' 142 628 170 36 $colRed $colDark
$btnKill.Add_Click({
    $marcados = @($lvProc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay procesos tildados.' 'warn'
        return
    }
    foreach ($name in $marcados) { Close-ProcessByName $name }
    Refresh-ProcessList
})

$btnPurge = New-Btn 'Purgar RAM caché' 320 628 150 36 $colTeal $colDark
$btnPurge.Add_Click({ Clear-StandbyMemory })

$btnStartup = New-Btn 'Apps de inicio' 478 628 130 36 $colSurface $colText
$btnStartup.Add_Click({ Show-StartupManager })

$btnSvcStop = New-Btn 'Pausar tildados' 730 628 130 36 $colSurface $colText
$btnSvcStop.Add_Click({
    $marcados = @($lvSvc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay servicios tildados.' 'warn'
        return
    }
    [void](Stop-ServicesByName $marcados)
    Refresh-ServiceList
})

$btnSvcStart = New-Btn 'Restaurar todo' 868 628 130 36 $colSurface $colText
$btnSvcStart.Add_Click({ Restore-Services })

$btnPing = New-Btn 'Test ping' 1006 628 134 36 $colBlue $colDark
$btnPing.Add_Click({ Test-PingLatency })

$btnNetOpt = New-Btn 'Optimizar PC' 730 672 200 36 $colAccent $colDark
$btnNetOpt.Add_Click({ Optimize-System })

$btnNetUndo = New-Btn 'Revertir tweaks' 938 672 202 36 $colSurface $colText
$btnNetUndo.Add_Click({ Restore-Tweaks })

# ----- Registro -----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'REGISTRO'
$lblLog.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblLog.ForeColor = $colDim
$lblLog.Location  = New-Object System.Drawing.Point(24, 678)
$lblLog.AutoSize  = $true
$form.Controls.Add($lblLog)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(24, 700)
$logBox.Size        = New-Object System.Drawing.Size(1116, 100)
$logBox.ReadOnly    = $true
$logBox.BackColor   = $colPanel
$logBox.ForeColor   = $colText
$logBox.BorderStyle = 'None'
$logBox.Font        = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

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
    $script:TickNum++
    [void]$script:RamHist.Add([pscustomobject]@{ Tick = $script:TickNum; UsedMB = $usada })
    while ($script:RamHist.Count -gt $script:HistCap) { $script:RamHist.RemoveAt(0) }

    $lblCardUsada.Text = '{0:N1} GB' -f ($usada / 1024)
    $lblCardLibre.Text = '{0:N1} GB' -f ($q[1] / 1024)
    $lblCardCarga.Text = '{0}%' -f $q[2]
    $lblCardCarga.ForeColor = if ($q[2] -ge 85) { $colRed } elseif ($q[2] -ge 70) { $colYellow } else { $colText }
    $lblCardPurga.Text = if ($script:PurgadoSesionMB -ge 1024) { '{0:N1} GB' -f ($script:PurgadoSesionMB / 1024) } else { '{0:N0} MB' -f $script:PurgadoSesionMB }

    $chartPanel.Invalidate()
}

function Test-AutoGaming {
    if (-not $chkAuto.Checked -or $script:BoostEnCurso) { return }
    $juego = Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-InList $_.Name $Config.juegos } | Select-Object -First 1
    if ($juego -and -not $script:JuegoDetectado) {
        $script:JuegoDetectado = $true
        Write-Log "Juego detectado: $($juego.Name)" 'title'
        Invoke-GamingMode -Silencioso
    } elseif (-not $juego) {
        $script:JuegoDetectado = $false
    }
}

$timerUI = New-Object System.Windows.Forms.Timer
$timerUI.Interval = 1000
$timerUI.Add_Tick({
    Update-Dashboard
    if ($script:TickNum % 5 -eq 0) { Test-AutoGaming }
})

# --- Arranque --------------------------------------------------
$form.Add_Shown({
    Update-Dashboard
    $timerUI.Start()
    Write-Log 'Booster v6 listo. Mirá el gráfico: cuando purgues la RAM vas a ver el bajón en vivo.' 'title'
    Refresh-ServiceList
    Refresh-ProcessList
})

$form.Add_FormClosed({ $timerUI.Stop() })

[void]$form.ShowDialog()
