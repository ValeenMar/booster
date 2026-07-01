# ============================================================
#  BOOSTER v5 - Optimizador gaming para despues del trabajo
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
    [StructLayout(LayoutKind.Sequential)]
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

# --- Paleta de colores ---------------------------------------
$colBg     = [System.Drawing.Color]::FromArgb(20, 20, 31)
$colPanel  = [System.Drawing.Color]::FromArgb(30, 30, 46)
$colAccent = [System.Drawing.Color]::FromArgb(137, 90, 246)
$colGreen  = [System.Drawing.Color]::FromArgb(94, 200, 120)
$colRed    = [System.Drawing.Color]::FromArgb(230, 90, 100)
$colText   = [System.Drawing.Color]::FromArgb(225, 225, 235)
$colDim    = [System.Drawing.Color]::FromArgb(140, 140, 160)

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
    if ($null -ne $antes) {
        Write-Log ("Memoria standby purgada: {0:N0} MB -> {1:N0} MB." -f $antes, (Get-StandbyMB)) 'ok'
    } else {
        # En algunas PCs los contadores de standby no están disponibles:
        # se informa con la RAM libre, que igual refleja el efecto
        Write-Log ("Memoria standby purgada (RAM libre: {0:N0} MB -> {1:N0} MB)." -f $libreAntes, (Get-FreeRamMB)) 'ok'
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
    $btnAplicar.ForeColor    = [System.Drawing.Color]::White
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
    $btnOk.ForeColor    = [System.Drawing.Color]::White
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

# --- GUI -------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Booster - Optimizador gaming'
$form.Size            = New-Object System.Drawing.Size(1010, 700)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $colBg
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'BOOSTER'
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $colAccent
$lblTitle.Location  = New-Object System.Drawing.Point(20, 12)
$lblTitle.AutoSize  = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'Liberá tu PC después del trabajo'
$lblSub.ForeColor = $colDim
$lblSub.Location  = New-Object System.Drawing.Point(24, 55)
$lblSub.AutoSize  = $true
$form.Controls.Add($lblSub)

$btnGaming = New-Object System.Windows.Forms.Button
$btnGaming.Text      = 'MODO GAMING'
$btnGaming.Font      = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$btnGaming.Location  = New-Object System.Drawing.Point(740, 15)
$btnGaming.Size      = New-Object System.Drawing.Size(230, 58)
$btnGaming.BackColor = $colAccent
$btnGaming.ForeColor = [System.Drawing.Color]::White
$btnGaming.FlatStyle = 'Flat'
$btnGaming.FlatAppearance.BorderSize = 0
$btnGaming.Add_Click({ Invoke-GamingMode })
$form.Controls.Add($btnGaming)

$chkTimer = New-Object System.Windows.Forms.CheckBox
$chkTimer.Text      = 'Timer 0,5 ms'
$chkTimer.Location  = New-Object System.Drawing.Point(620, 33)
$chkTimer.Size      = New-Object System.Drawing.Size(112, 24)
$chkTimer.ForeColor = $colText
$chkTimer.Add_CheckedChanged({ Set-TimerResolution $chkTimer.Checked })
$form.Controls.Add($chkTimer)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text      = 'Auto-gaming'
$chkAuto.Location  = New-Object System.Drawing.Point(620, 55)
$chkAuto.Size      = New-Object System.Drawing.Size(112, 24)
$chkAuto.ForeColor = $colText
$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) {
        Write-Log "Auto-gaming ON: al detectar un juego (lista 'juegos' del config) se activa el modo gaming solo, sin diálogos." 'info'
    } else {
        Write-Log 'Auto-gaming desactivado.' 'info'
    }
})
$form.Controls.Add($chkAuto)

# Detector de juegos: revisa cada 5 segundos si arrancó un juego
$script:JuegoDetectado = $false
$script:BoostEnCurso   = $false
$timerAuto = New-Object System.Windows.Forms.Timer
$timerAuto.Interval = 5000
$timerAuto.Add_Tick({
    if (-not $chkAuto.Checked -or $script:BoostEnCurso) { return }
    $juego = Get-Process -ErrorAction SilentlyContinue | Where-Object { Test-InList $_.Name $Config.juegos } | Select-Object -First 1
    if ($juego -and -not $script:JuegoDetectado) {
        $script:JuegoDetectado = $true
        Write-Log "Juego detectado: $($juego.Name)" 'title'
        Invoke-GamingMode -Silencioso
    } elseif (-not $juego) {
        $script:JuegoDetectado = $false
    }
})
$timerAuto.Start()

# ----- Panel de procesos -----
$lblProc = New-Object System.Windows.Forms.Label
$lblProc.Text      = 'Procesos que más consumen (tildá y cerrá los que quieras)'
$lblProc.ForeColor = $colText
$lblProc.Location  = New-Object System.Drawing.Point(20, 90)
$lblProc.AutoSize  = $true
$form.Controls.Add($lblProc)

$lvProc = New-Object System.Windows.Forms.ListView
$lvProc.Location      = New-Object System.Drawing.Point(20, 115)
$lvProc.Size          = New-Object System.Drawing.Size(580, 340)
$lvProc.View          = 'Details'
$lvProc.CheckBoxes    = $true
$lvProc.FullRowSelect = $true
$lvProc.BackColor     = $colPanel
$lvProc.ForeColor     = $colText
$lvProc.BorderStyle   = 'FixedSingle'
[void]$lvProc.Columns.Add('Proceso', 190)
[void]$lvProc.Columns.Add('Instancias', 75)
[void]$lvProc.Columns.Add('RAM (MB)', 100)
[void]$lvProc.Columns.Add('CPU (%)', 80)
[void]$lvProc.Columns.Add('Fondo', 60)
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

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = 'Actualizar'
$btnRefresh.Location  = New-Object System.Drawing.Point(20, 465)
$btnRefresh.Size      = New-Object System.Drawing.Size(130, 34)
$btnRefresh.BackColor = $colPanel
$btnRefresh.ForeColor = $colText
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.Add_Click({ Refresh-ProcessList })
$form.Controls.Add($btnRefresh)

$btnKill = New-Object System.Windows.Forms.Button
$btnKill.Text      = 'Cerrar seleccionados'
$btnKill.Location  = New-Object System.Drawing.Point(160, 465)
$btnKill.Size      = New-Object System.Drawing.Size(180, 34)
$btnKill.BackColor = $colRed
$btnKill.ForeColor = [System.Drawing.Color]::White
$btnKill.FlatStyle = 'Flat'
$btnKill.Add_Click({
    $marcados = @($lvProc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay procesos tildados.' 'warn'
        return
    }
    foreach ($name in $marcados) { Close-ProcessByName $name }
    Refresh-ProcessList
})
$form.Controls.Add($btnKill)

$btnPurge = New-Object System.Windows.Forms.Button
$btnPurge.Text      = 'Purgar RAM caché'
$btnPurge.Location  = New-Object System.Drawing.Point(350, 465)
$btnPurge.Size      = New-Object System.Drawing.Size(130, 34)
$btnPurge.BackColor = $colPanel
$btnPurge.ForeColor = $colText
$btnPurge.FlatStyle = 'Flat'
$btnPurge.Add_Click({ Clear-StandbyMemory })
$form.Controls.Add($btnPurge)

$btnStartup = New-Object System.Windows.Forms.Button
$btnStartup.Text      = 'Apps de inicio'
$btnStartup.Location  = New-Object System.Drawing.Point(490, 465)
$btnStartup.Size      = New-Object System.Drawing.Size(110, 34)
$btnStartup.BackColor = $colPanel
$btnStartup.ForeColor = $colText
$btnStartup.FlatStyle = 'Flat'
$btnStartup.Add_Click({ Show-StartupManager })
$form.Controls.Add($btnStartup)

# ----- Panel de servicios -----
$lblSvc = New-Object System.Windows.Forms.Label
$lblSvc.Text      = 'Servicios (Windows + terceros detectados)'
$lblSvc.ForeColor = $colText
$lblSvc.Location  = New-Object System.Drawing.Point(620, 90)
$lblSvc.AutoSize  = $true
$form.Controls.Add($lblSvc)

$lvSvc = New-Object System.Windows.Forms.ListView
$lvSvc.Location      = New-Object System.Drawing.Point(620, 115)
$lvSvc.Size          = New-Object System.Drawing.Size(350, 300)
$lvSvc.View          = 'Details'
$lvSvc.CheckBoxes    = $true
$lvSvc.FullRowSelect = $true
$lvSvc.BackColor     = $colPanel
$lvSvc.ForeColor     = $colText
$lvSvc.BorderStyle   = 'FixedSingle'
[void]$lvSvc.Columns.Add('Servicio', 175)
[void]$lvSvc.Columns.Add('Estado', 80)
[void]$lvSvc.Columns.Add('Origen', 70)
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

$btnSvcStop = New-Object System.Windows.Forms.Button
$btnSvcStop.Text      = 'Pausar tildados'
$btnSvcStop.Location  = New-Object System.Drawing.Point(620, 425)
$btnSvcStop.Size      = New-Object System.Drawing.Size(165, 34)
$btnSvcStop.BackColor = $colPanel
$btnSvcStop.ForeColor = $colText
$btnSvcStop.FlatStyle = 'Flat'
$btnSvcStop.Add_Click({
    $marcados = @($lvSvc.CheckedItems | ForEach-Object { $_.Text })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay servicios tildados.' 'warn'
        return
    }
    [void](Stop-ServicesByName $marcados)
    Refresh-ServiceList
})
$form.Controls.Add($btnSvcStop)

$btnSvcStart = New-Object System.Windows.Forms.Button
$btnSvcStart.Text      = 'Restaurar todo'
$btnSvcStart.Location  = New-Object System.Drawing.Point(800, 425)
$btnSvcStart.Size      = New-Object System.Drawing.Size(170, 34)
$btnSvcStart.BackColor = $colPanel
$btnSvcStart.ForeColor = $colText
$btnSvcStart.FlatStyle = 'Flat'
$btnSvcStart.Add_Click({ Restore-Services })
$form.Controls.Add($btnSvcStart)

# ----- Botones de red -----
$btnNetOpt = New-Object System.Windows.Forms.Button
$btnNetOpt.Text      = 'Optimizar PC'
$btnNetOpt.Location  = New-Object System.Drawing.Point(620, 465)
$btnNetOpt.Size      = New-Object System.Drawing.Size(115, 34)
$btnNetOpt.BackColor = $colAccent
$btnNetOpt.ForeColor = [System.Drawing.Color]::White
$btnNetOpt.FlatStyle = 'Flat'
$btnNetOpt.FlatAppearance.BorderSize = 0
$btnNetOpt.Add_Click({ Optimize-System })
$form.Controls.Add($btnNetOpt)

$btnNetUndo = New-Object System.Windows.Forms.Button
$btnNetUndo.Text      = 'Revertir tweaks'
$btnNetUndo.Location  = New-Object System.Drawing.Point(745, 465)
$btnNetUndo.Size      = New-Object System.Drawing.Size(115, 34)
$btnNetUndo.BackColor = $colPanel
$btnNetUndo.ForeColor = $colText
$btnNetUndo.FlatStyle = 'Flat'
$btnNetUndo.Add_Click({ Restore-Tweaks })
$form.Controls.Add($btnNetUndo)

$btnPing = New-Object System.Windows.Forms.Button
$btnPing.Text      = 'Test ping'
$btnPing.Location  = New-Object System.Drawing.Point(870, 465)
$btnPing.Size      = New-Object System.Drawing.Size(100, 34)
$btnPing.BackColor = $colPanel
$btnPing.ForeColor = $colText
$btnPing.FlatStyle = 'Flat'
$btnPing.Add_Click({ Test-PingLatency })
$form.Controls.Add($btnPing)

# ----- Registro -----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'Registro'
$lblLog.ForeColor = $colDim
$lblLog.Location  = New-Object System.Drawing.Point(20, 508)
$lblLog.AutoSize  = $true
$form.Controls.Add($lblLog)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(20, 530)
$logBox.Size        = New-Object System.Drawing.Size(950, 115)
$logBox.ReadOnly    = $true
$logBox.BackColor   = $colPanel
$logBox.ForeColor   = $colText
$logBox.BorderStyle = 'FixedSingle'
$logBox.Font        = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

function Write-Log([string]$msg, [string]$kind = 'info') {
    $color = switch ($kind) {
        'ok'    { $colGreen }
        'err'   { $colRed }
        'warn'  { [System.Drawing.Color]::FromArgb(230, 200, 90) }
        'title' { $colAccent }
        default { $colDim }
    }
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionColor  = $color
    $logBox.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + "`r`n")
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# --- Arranque --------------------------------------------------
$form.Add_Shown({
    Write-Log 'Booster v5 listo. Tildá Auto-gaming para que se active solo al detectar un juego.' 'title'
    Refresh-ServiceList
    Refresh-ProcessList
})

[void]$form.ShowDialog()
