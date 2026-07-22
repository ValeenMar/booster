# ============================================================
#  BOOSTER RESCATE v1 - Limpieza de ladrones de token de Discord
#  (campana del "regalo de MrBeast" / casino cripto trucho)
#
#  NO es un antivirus generico: es un cazador dirigido a las
#  mananas concretas de esta familia de malware. Todo lo que
#  toca va a CUARENTENA (movido, no borrado) con manifiesto
#  JSON para poder restaurarlo.
#
#  Complementa a Microsoft Defender, no lo reemplaza.
# ============================================================
#Requires -Version 5.1

# --- Auto-elevación (hace falta para ver exclusiones y tareas) ---
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Paleta (Catppuccin Mocha, igual que Booster) --------------
$colBg      = [System.Drawing.Color]::FromArgb(17, 17, 27)
$colPanel   = [System.Drawing.Color]::FromArgb(30, 30, 46)
$colSurface = [System.Drawing.Color]::FromArgb(49, 50, 68)
$colAccent  = [System.Drawing.Color]::FromArgb(203, 166, 247)
$colGreen   = [System.Drawing.Color]::FromArgb(166, 227, 161)
$colRed     = [System.Drawing.Color]::FromArgb(243, 139, 168)
$colYellow  = [System.Drawing.Color]::FromArgb(249, 226, 175)
$colBlue    = [System.Drawing.Color]::FromArgb(137, 180, 250)
$colText    = [System.Drawing.Color]::FromArgb(205, 214, 244)
$colDim     = [System.Drawing.Color]::FromArgb(147, 153, 178)
$colDark    = [System.Drawing.Color]::FromArgb(17, 17, 27)

$script:Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:QuarDir    = Join-Path $Dir 'Cuarentena'
$script:Hallazgos  = @()
$script:LogBox     = $null

# El index.js legítimo de Discord es EXACTAMENTE esta línea.
# Si tiene cualquier otra cosa, el cliente está parcheado.
$script:DiscordCoreLimpio = "module.exports = require('./core.asar');" + [char]10

function Write-Log([string]$msg, [string]$kind = 'info') {
    if ($null -eq $script:LogBox) { return }
    $color = switch ($kind) {
        'ok'    { $colGreen }
        'err'   { $colRed }
        'warn'  { $colYellow }
        'title' { $colAccent }
        default { $colDim }
    }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.SelectionColor = $color
    $script:LogBox.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + "`r`n")
    $script:LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# --- Helpers ---------------------------------------------------
function New-Hallazgo($sev, $tipo, $que, $donde, $datos) {
    [pscustomobject]@{ Sev = $sev; Tipo = $tipo; Que = $que; Donde = $donde; Datos = $datos }
}

function Test-RutaDelSistema([string]$ruta) {
    # Nunca tocamos nada dentro de C:\Windows
    if (-not $ruta) { return $false }
    return $ruta -like "$env:WINDIR*"
}

function Test-RutaSospechosa([string]$ruta) {
    # Carpetas donde el usuario puede escribir: ahí vive el malware,
    # el software serio se instala en Program Files
    if (-not $ruta) { return $false }
    if (Test-RutaConfiable $ruta) { return $false }
    foreach ($p in @($env:TEMP, "$env:WINDIR\Temp", $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData, "$env:USERPROFILE\Downloads")) {
        if ($p -and $ruta -like "$p*") { return $true }
    }
    return $false
}

function Test-RutaConfiable([string]$ruta) {
    # Program Files, Windows, los alias de apps de la Store y la carpeta
    # de esta misma herramienta: nada de esto se reporta jamás
    if (-not $ruta) { return $false }
    $confiables = @("$env:WINDIR", "$env:ProgramFiles", "${env:ProgramFiles(x86)}",
                    "$env:LOCALAPPDATA\Microsoft\WindowsApps", "$env:ProgramFiles\WindowsApps")
    foreach ($p in $confiables) {
        if ($p -and $ruta -like "$p*") { return $true }
    }
    return $false
}

function Test-ArchivoPropio([string]$ruta) {
    # Los archivos de esta herramienta llevan las URLs de webhook como
    # patrones de busqueda: se excluyen ELLOS, no su carpeta (si esto vive
    # en Descargas, el resto de Descargas se tiene que seguir revisando)
    if (-not $ruta) { return $false }
    foreach ($propio in @('Rescate.ps1', 'Booster.ps1')) {
        if ($ruta -ieq (Join-Path $script:Dir $propio)) { return $true }
    }
    return ($script:QuarDir -and $ruta -like "$($script:QuarDir)*")
}

function Get-UbicacionDeMalware([string]$ruta) {
    # Un ejecutable en Temp, o suelto en la RAIZ de AppData, es el patrón
    # del dropper. En subcarpetas de AppData vive un montón de software
    # legítimo sin firmar (herramientas de desarrollo, runtimes), así que
    # ahí no se reporta nada.
    if (-not $ruta) { return $null }
    if (Test-RutaConfiable $ruta) { return $null }
    foreach ($p in @($env:TEMP, "$env:WINDIR\Temp", "$env:LOCALAPPDATA\Temp")) {
        if ($p -and $ruta -like "$p*") { return 'temp' }
    }
    $padre = Split-Path $ruta -Parent
    foreach ($p in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData)) {
        if ($p -and $padre -and $padre.TrimEnd('\') -ieq $p.TrimEnd('\')) { return 'raiz' }
    }
    return $null
}

function Resolve-Acceso([string]$lnk) {
    # Un .lnk no se puede firmar: lo que importa es a dónde apunta
    try {
        $sh = New-Object -ComObject WScript.Shell
        return $sh.CreateShortcut($lnk).TargetPath
    } catch { return $null }
}

function Get-ExeDeComando([string]$cmd) {
    # Saca la ruta del ejecutable de una línea de comando con o sin comillas
    if (-not $cmd) { return $null }
    $cmd = $cmd.Trim()
    if ($cmd.StartsWith('"')) {
        $fin = $cmd.IndexOf('"', 1)
        if ($fin -gt 1) { return $cmd.Substring(1, $fin - 1) }
    }
    $m = [regex]::Match($cmd, '^[^\s]+')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-FirmaEstado([string]$ruta) {
    # 'Firmado' | 'SIN FIRMA' | 'ilegible'. La firma es el mejor
    # discriminador, pero hay que separar "no está firmado" de "Windows
    # no me deja leerlo" (apps de la Store): confundirlos llenaba el
    # informe de falsos positivos.
    if (-not $ruta) { return 'ilegible' }
    if (-not (Test-Path -LiteralPath $ruta -PathType Leaf -ErrorAction SilentlyContinue)) { return 'ilegible' }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $ruta -ErrorAction Stop
        if ($null -eq $s) { return 'ilegible' }
        switch ([string]$s.Status) {
            'Valid'        { return 'Firmado' }
            'NotSigned'    { return 'SIN FIRMA' }
            'HashMismatch' { return 'SIN FIRMA' }
            'NotTrusted'   { return 'SIN FIRMA' }
            default        { return 'ilegible' }
        }
    } catch { return 'ilegible' }
}

function Test-ArchivoConWebhook([string]$ruta) {
    # Los stealers llevan la URL del webhook de Discord en texto plano
    # (hasta los empaquetados con PyInstaller). Señal altísima.
    try {
        $fi = Get-Item -LiteralPath $ruta -Force -ErrorAction Stop
        if ($fi.Length -gt 25MB -or $fi.Length -lt 32) { return $null }
        $bytes = [IO.File]::ReadAllBytes($fi.FullName)
        $txt = [Text.Encoding]::ASCII.GetString($bytes)
        foreach ($pat in @('discord.com/api/webhooks', 'discordapp.com/api/webhooks', 'canary.discord.com/api/webhooks')) {
            if ($txt.Contains($pat)) { return $pat }
        }
    } catch {}
    return $null
}

# --- Escaneos --------------------------------------------------
function Scan-DiscordInyectado {
    # El truco estrella: parchear el index.js del cliente para robar
    # el token cada vez que abrís Discord.
    $res = @()
    foreach ($base in @("$env:LOCALAPPDATA\Discord", "$env:LOCALAPPDATA\DiscordCanary", "$env:LOCALAPPDATA\DiscordPTB", "$env:LOCALAPPDATA\DiscordDevelopment")) {
        if (-not (Test-Path $base)) { continue }
        $archivos = Get-ChildItem $base -Recurse -Filter 'index.js' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -match 'discord_desktop_core' }
        foreach ($f in $archivos) {
            $contenido = ''
            try { $contenido = [IO.File]::ReadAllText($f.FullName) } catch { continue }
            if ($contenido.Trim() -ne $script:DiscordCoreLimpio.Trim()) {
                $res += New-Hallazgo 'CRITICO' 'Discord' 'Cliente de Discord PARCHEADO (roba el token al abrir)' $f.FullName @{ Kind = 'discord'; Path = $f.FullName; Contenido = $contenido }
            }
        }
    }
    # BetterDiscord y similares no son malware, pero el malware se
    # disfraza de plugin: se avisa sin proponer borrarlo.
    foreach ($mod in @("$env:APPDATA\BetterDiscord\plugins", "$env:APPDATA\Vencord\plugins")) {
        if (Test-Path $mod) {
            $n = @(Get-ChildItem $mod -File -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) { Write-Log "Nota: hay $n plugin(s) de cliente modificado en $mod. No los toco, pero revisalos a mano si no los pusiste vos." 'warn' }
        }
    }
    return $res
}

function Scan-Defender {
    $res = @()
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if (-not $st.RealTimeProtectionEnabled) {
            $res += New-Hallazgo 'CRITICO' 'Defender' 'La proteccion en tiempo real de Defender esta APAGADA' 'Microsoft Defender' @{ Kind = 'defender-rt' }
        }
    } catch {}
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        foreach ($ex in @($pref.ExclusionPath)) {
            if (-not $ex) { continue }
            # Una exclusion en carpeta de usuario casi siempre la puso el malware
            if (Test-RutaSospechosa $ex) {
                $res += New-Hallazgo 'ALTO' 'Defender' 'Exclusion de Defender en carpeta de usuario (tipica del malware)' $ex @{ Kind = 'defender-excl'; Path = $ex }
            }
        }
    } catch {}
    return $res
}

function Scan-Autoarranque {
    $res = @()
    $claves = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';                  Et = 'HKCU Run' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';              Et = 'HKCU RunOnce' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                  Et = 'HKLM Run' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';              Et = 'HKLM RunOnce' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';      Et = 'HKLM Run 32b' }
    )
    foreach ($k in $claves) {
        if (-not (Test-Path $k.Path)) { continue }
        $p = Get-ItemProperty $k.Path -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if (@('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') -contains $prop.Name) { continue }
            $cmd = [string]$prop.Value
            $exe = Get-ExeDeComando $cmd
            if (Test-RutaDelSistema $exe) { continue }
            if (-not (Test-RutaSospechosa $exe)) { continue }
            # Solo lo que es DEFINITIVAMENTE sin firma: si no se puede leer
            # (apps de la Store) no se reporta
            if ((Get-FirmaEstado $exe) -ne 'SIN FIRMA') { continue }
            $sev = if ($exe -like "$env:TEMP*") { 'CRITICO' } else { 'ALTO' }
            $res += New-Hallazgo $sev 'Inicio' 'Arranca con Windows desde carpeta de usuario y SIN FIRMA' "$($k.Et) -> $($prop.Name) = $cmd" @{
                Kind = 'run'; Hive = $k.Path; Name = $prop.Name; Value = $cmd; Exe = $exe
            }
        }
    }
    # Carpetas de Inicio
    foreach ($carpeta in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $carpeta -or -not (Test-Path $carpeta)) { continue }
        foreach ($f in (Get-ChildItem $carpeta -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $esScript = $f.Extension -match '^\.(vbs|js|bat|cmd|ps1|jse|vbe|wsf|scr|pif|hta)$'
            if ($esScript) {
                $res += New-Hallazgo 'ALTO' 'Inicio' 'Script en la carpeta de Inicio (los programas normales ponen accesos directos, no scripts)' $f.FullName @{ Kind = 'file'; Path = $f.FullName }
                continue
            }
            # Un acceso directo no se puede firmar: se juzga su destino
            $objetivo = if ($f.Extension -ieq '.lnk') { Resolve-Acceso $f.FullName } else { $f.FullName }
            if (-not $objetivo) { continue }
            if (Test-RutaConfiable $objetivo) { continue }
            if (-not (Test-RutaSospechosa $objetivo)) { continue }
            if ((Get-FirmaEstado $objetivo) -ne 'SIN FIRMA') { continue }
            $res += New-Hallazgo 'ALTO' 'Inicio' 'Arranque desde carpeta de usuario y SIN FIRMA' "$($f.Name) -> $objetivo" @{ Kind = 'file'; Path = $f.FullName }
        }
    }
    return $res
}

# Marcas de un comando malicioso de verdad. Una tarea con
# "-ExecutionPolicy Bypass -File script.ps1" es de lo más normal (backups,
# utilidades); lo que delata al malware es el comando codificado o la
# descarga en linea.
$script:MarcasMaliciosas = @(
    '-enc', '-encodedcommand', 'frombase64string', 'downloadstring', 'downloadfile',
    'invoke-webrequest', 'invoke-expression', 'iex(', 'iex ', 'certutil', 'bitsadmin',
    'http://', 'https://'
)

function Test-ComandoMalicioso([string]$comando) {
    # OJO: el parametro NO se puede llamar $args (es variable automatica de
    # PowerShell y el valor recibido se pierde: la deteccion quedaba muerta)
    if (-not $comando) { return $null }
    $low = $comando.ToLower()
    foreach ($m in $script:MarcasMaliciosas) {
        if ($low.Contains($m)) { return $m }
    }
    return $null
}

function Scan-Tareas {
    $res = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }   # tareas del propio Windows
        foreach ($a in @($t.Actions)) {
            $exe = $a.Execute
            if (-not $exe) { continue }
            $exe = $exe.Trim('"')
            if ($exe -match '^(powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32)(\.exe)?$' -or $exe -match '\\(powershell|pwsh|cmd|wscript|cscript|mshta)\.exe$') {
                $marca = Test-ComandoMalicioso ([string]$a.Arguments)
                if (-not $marca) { continue }   # intérprete con argumentos normales: se deja en paz
                $res += New-Hallazgo 'ALTO' 'Tarea' "Tarea programada con comando oculto o descarga en linea (`"$marca`")" "$($t.TaskPath)$($t.TaskName)" @{
                    Kind = 'task'; Name = $t.TaskName; Path = $t.TaskPath
                }
                continue
            }
            if (Test-RutaDelSistema $exe) { continue }
            if (-not (Test-RutaSospechosa $exe)) { continue }
            if ((Get-FirmaEstado $exe) -ne 'SIN FIRMA') { continue }
            $res += New-Hallazgo 'ALTO' 'Tarea' 'Tarea programada que corre algo SIN FIRMA desde carpeta de usuario' "$($t.TaskPath)$($t.TaskName) -> $exe" @{
                Kind = 'task'; Name = $t.TaskName; Path = $t.TaskPath; Exe = $exe
            }
        }
    }
    return $res
}

function Scan-Procesos {
    $res = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $ruta = $null
        try { $ruta = $p.Path } catch {}
        if (-not $ruta) { continue }
        if (Test-RutaDelSistema $ruta) { continue }
        # Solo Temp o suelto en la raíz de AppData: en subcarpetas de AppData
        # corre muchísimo software legítimo sin firmar
        $ubi = Get-UbicacionDeMalware $ruta
        if (-not $ubi) { continue }
        if ((Get-FirmaEstado $ruta) -ne 'SIN FIRMA') { continue }
        $sev = if ($ubi -eq 'temp') { 'CRITICO' } else { 'ALTO' }
        $donde = if ($ubi -eq 'temp') { 'desde una carpeta temporal' } else { 'suelto en la raiz de AppData' }
        $res += New-Hallazgo $sev 'Proceso' "Proceso SIN FIRMA corriendo $donde" "$($p.Name) (PID $($p.Id)) -> $ruta" @{
            Kind = 'proc'; Pid = $p.Id; Name = $p.Name; Path = $ruta
        }
    }
    return $res
}

function Scan-Webhooks {
    $res = @()
    $dirs = @($env:TEMP, "$env:APPDATA", "$env:LOCALAPPDATA\Temp", [Environment]::GetFolderPath('Startup'), "$env:USERPROFILE\Downloads")
    $exts = @('.exe','.js','.bat','.cmd','.vbs','.ps1','.py','.jar','.scr','.hta','.wsf')
    $vistos = @{}
    $binarios = @('.exe', '.scr', '.jar', '.pif')
    foreach ($d in $dirs) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        $archivos = Get-ChildItem $d -File -Force -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Where-Object { $exts -contains $_.Extension.ToLower() } |
                    Select-Object -First 900
        foreach ($f in $archivos) {
            if ($vistos.ContainsKey($f.FullName)) { continue }
            $vistos[$f.FullName] = $true
            # Cada llamada va entre parentesis: sin eso PowerShell toma el
            # -or como un argumento mas de la funcion y la condicion no filtra
            if ((Test-RutaConfiable $f.FullName) -or (Test-ArchivoPropio $f.FullName)) { continue }
            $hit = Test-ArchivoConWebhook $f.FullName
            if (-not $hit) { continue }
            if ($binarios -contains $f.Extension.ToLower()) {
                # Un ejecutable con un webhook adentro es, casi siempre, un stealer
                $res += New-Hallazgo 'CRITICO' 'Webhook' "Ejecutable con webhook de Discord adentro ($hit): asi se manda el token robado" $f.FullName @{ Kind = 'file'; Path = $f.FullName }
            } else {
                # En un script puede ser un proyecto propio de bots: se avisa, no se asume
                $res += New-Hallazgo 'ALTO' 'Webhook' "Script con webhook de Discord adentro ($hit). Si es un proyecto tuyo de bots, destildalo" $f.FullName @{ Kind = 'file'; Path = $f.FullName }
            }
        }
    }
    return $res
}

function Scan-Hosts {
    $res = @()
    $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
    if (-not (Test-Path $hosts)) { return $res }
    $malas = @()
    foreach ($linea in (Get-Content $hosts -ErrorAction SilentlyContinue)) {
        $l = $linea.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '(microsoft|windowsupdate|defender|malwarebytes|avast|kaspersky|bitdefender|virustotal|eset|norton|mcafee)') {
            $malas += $linea
        }
    }
    if ($malas.Count -gt 0) {
        $res += New-Hallazgo 'ALTO' 'Hosts' "El archivo hosts bloquea $($malas.Count) dominio(s) de antivirus/Windows Update" $hosts @{ Kind = 'hosts'; Lineas = $malas }
    }
    return $res
}

function Scan-WMI {
    # Persistencia avanzada: consumidores WMI que ejecutan comandos solos
    $res = @()
    foreach ($clase in @('CommandLineEventConsumer', 'ActiveScriptEventConsumer')) {
        foreach ($c in @(Get-CimInstance -Namespace root\subscription -ClassName $clase -ErrorAction SilentlyContinue)) {
            if ($c.Name -eq 'SCM Event Log Consumer') { continue }   # viene con Windows
            $det = if ($c.CommandLineTemplate) { $c.CommandLineTemplate } else { $c.ScriptText }
            $res += New-Hallazgo 'ALTO' 'WMI' "Persistencia por WMI ($clase): ejecuta comandos sin que lo veas" "$($c.Name) -> $det" @{
                Kind = 'wmi'; Clase = $clase; Name = $c.Name
            }
        }
    }
    return $res
}

function Invoke-Escaneo {
    $btnScan.Enabled = $false
    $form.Cursor = 'WaitCursor'
    $lv.Items.Clear()
    $script:Hallazgos = @()
    Write-Log '=== ESCANEO INICIADO ===' 'title'

    $pasos = @(
        @{ N = 'Cliente de Discord';   F = { Scan-DiscordInyectado } },
        @{ N = 'Microsoft Defender';   F = { Scan-Defender } },
        @{ N = 'Arranque de Windows';  F = { Scan-Autoarranque } },
        @{ N = 'Tareas programadas';   F = { Scan-Tareas } },
        @{ N = 'Procesos corriendo';   F = { Scan-Procesos } },
        @{ N = 'Archivo hosts';        F = { Scan-Hosts } },
        @{ N = 'Persistencia WMI';     F = { Scan-WMI } },
        @{ N = 'Webhooks en archivos'; F = { Scan-Webhooks } }
    )
    foreach ($paso in $pasos) {
        Write-Log "Revisando: $($paso.N)..." 'info'
        try {
            $r = @(& $paso.F)
            if ($r.Count -gt 0) {
                $script:Hallazgos += $r
                Write-Log "  -> $($r.Count) hallazgo(s)" 'warn'
            }
        } catch {
            Write-Log "  -> error revisando $($paso.N): $($_.Exception.Message)" 'err'
        }
    }

    $orden = @{ 'CRITICO' = 0; 'ALTO' = 1; 'MEDIO' = 2 }
    $script:Hallazgos = @($script:Hallazgos | Sort-Object { $orden[$_.Sev] })
    foreach ($h in $script:Hallazgos) {
        $item = New-Object System.Windows.Forms.ListViewItem($h.Sev)
        [void]$item.SubItems.Add($h.Tipo)
        [void]$item.SubItems.Add($h.Que)
        [void]$item.SubItems.Add($h.Donde)
        $item.Tag = $h
        $item.Checked = ($h.Sev -ne 'MEDIO')   # los MEDIO quedan sin tildar: mirálos vos
        $item.ForeColor = switch ($h.Sev) {
            'CRITICO' { $colRed }
            'ALTO'    { $colYellow }
            default   { $colDim }
        }
        [void]$lv.Items.Add($item)
    }

    if ($script:Hallazgos.Count -eq 0) {
        Write-Log '=== LIMPIO: no encontre nada de esta familia de malware en la PC ===' 'ok'
        Write-Log 'OJO: eso NO significa que la cuenta este a salvo. Si igual manda spam, le robaron el token por otra via (web trucha, QR de "nitro gratis").' 'warn'
        Write-Log 'Toca "Guia de la cuenta" y segui los pasos: cambiar la contrasena es lo que corta el robo.' 'title'
    } else {
        $crit = @($script:Hallazgos | Where-Object { $_.Sev -eq 'CRITICO' }).Count
        Write-Log "=== $($script:Hallazgos.Count) hallazgo(s), $crit critico(s) ===" 'title'
        Write-Log 'Revisa la lista, destilda lo que reconozcas como tuyo y toca "Limpiar tildados". Todo va a cuarentena: se puede restaurar.' 'info'
    }
    $form.Cursor = 'Default'
    $btnScan.Enabled = $true
}

# --- Limpieza (todo reversible) ---------------------------------
function Invoke-Limpieza {
    $marcados = @($lv.CheckedItems | ForEach-Object { $_.Tag })
    if ($marcados.Count -eq 0) {
        Write-Log 'No hay nada tildado.' 'warn'
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Voy a neutralizar $($marcados.Count) hallazgo(s).`n`nNada se borra: los archivos se MUEVEN a la carpeta Cuarentena y las claves/tareas se guardan en un manifiesto para poder restaurarlas.`n`n¿Sigo?",
        'Booster Rescate', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    $sello = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $destino = Join-Path $QuarDir $sello
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    $manifiesto = @()
    $ok = 0; $fallo = 0

    Write-Log '=== LIMPIEZA ===' 'title'
    foreach ($h in $marcados) {
        $d = $h.Datos
        try {
            switch ($d.Kind) {
                'discord' {
                    $bk = Join-Path $destino ('discord_index_{0}.js.bak' -f $ok)
                    [IO.File]::WriteAllText($bk, $d.Contenido)
                    [IO.File]::WriteAllText($d.Path, $script:DiscordCoreLimpio)
                    $manifiesto += @{ Kind = 'discord'; Path = $d.Path; Backup = $bk }
                    Write-Log "Cliente de Discord restaurado a su version limpia: $($d.Path)" 'ok'
                }
                'defender-rt' {
                    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                    $manifiesto += @{ Kind = 'defender-rt' }
                    Write-Log 'Proteccion en tiempo real de Defender REACTIVADA.' 'ok'
                }
                'defender-excl' {
                    Remove-MpPreference -ExclusionPath $d.Path -ErrorAction Stop
                    $manifiesto += @{ Kind = 'defender-excl'; Path = $d.Path }
                    Write-Log "Exclusion de Defender eliminada: $($d.Path)" 'ok'
                }
                'run' {
                    $manifiesto += @{ Kind = 'run'; Hive = $d.Hive; Name = $d.Name; Value = $d.Value }
                    Remove-ItemProperty -Path $d.Hive -Name $d.Name -ErrorAction Stop
                    Write-Log "Autoarranque quitado: $($d.Name)" 'ok'
                    if ($d.Exe -and (Test-Path -LiteralPath $d.Exe)) {
                        $dst = Join-Path $destino (Split-Path $d.Exe -Leaf)
                        Move-Item -LiteralPath $d.Exe -Destination $dst -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $dst) {
                            $manifiesto += @{ Kind = 'file'; Path = $d.Exe; Backup = $dst }
                            Write-Log "  archivo a cuarentena: $($d.Exe)" 'ok'
                        }
                    }
                }
                'task' {
                    $xml = Export-ScheduledTask -TaskName $d.Name -TaskPath $d.Path -ErrorAction Stop
                    $bk = Join-Path $destino ('tarea_{0}.xml' -f ($d.Name -replace '[^\w\-]', '_'))
                    [IO.File]::WriteAllText($bk, $xml)
                    Unregister-ScheduledTask -TaskName $d.Name -TaskPath $d.Path -Confirm:$false -ErrorAction Stop
                    $manifiesto += @{ Kind = 'task'; Name = $d.Name; Path = $d.Path; Backup = $bk }
                    Write-Log "Tarea programada eliminada: $($d.Name)" 'ok'
                }
                'proc' {
                    Stop-Process -Id $d.Pid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 300
                    Write-Log "Proceso terminado: $($d.Name) (PID $($d.Pid))" 'ok'
                    if (Test-Path -LiteralPath $d.Path) {
                        $dst = Join-Path $destino (Split-Path $d.Path -Leaf)
                        Move-Item -LiteralPath $d.Path -Destination $dst -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $dst) {
                            $manifiesto += @{ Kind = 'file'; Path = $d.Path; Backup = $dst }
                            Write-Log "  archivo a cuarentena: $($d.Path)" 'ok'
                        }
                    }
                }
                'file' {
                    $dst = Join-Path $destino (Split-Path $d.Path -Leaf)
                    $i = 1
                    while (Test-Path -LiteralPath $dst) { $dst = Join-Path $destino ("{0}_{1}" -f $i, (Split-Path $d.Path -Leaf)); $i++ }
                    Move-Item -LiteralPath $d.Path -Destination $dst -Force -ErrorAction Stop
                    $manifiesto += @{ Kind = 'file'; Path = $d.Path; Backup = $dst }
                    Write-Log "A cuarentena: $($d.Path)" 'ok'
                }
                'hosts' {
                    $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
                    $bk = Join-Path $destino 'hosts.bak'
                    Copy-Item $hosts $bk -Force
                    $original = Get-Content $hosts
                    $limpio = $original | Where-Object { $d.Lineas -notcontains $_ }
                    Set-Content -Path $hosts -Value $limpio -Encoding ASCII -Force
                    $manifiesto += @{ Kind = 'hosts'; Path = $hosts; Backup = $bk }
                    Write-Log "Archivo hosts limpiado ($($d.Lineas.Count) linea(s) sacadas)." 'ok'
                }
                'wmi' {
                    Get-CimInstance -Namespace root\subscription -ClassName $d.Clase -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq $d.Name } | Remove-CimInstance -ErrorAction Stop
                    $manifiesto += @{ Kind = 'wmi'; Clase = $d.Clase; Name = $d.Name }
                    Write-Log "Persistencia WMI eliminada: $($d.Name) (no se puede restaurar automaticamente)" 'ok'
                }
                default { Write-Log "Tipo desconocido, salteado: $($d.Kind)" 'warn' }
            }
            $ok++
        } catch {
            $fallo++
            Write-Log "No pude neutralizar '$($h.Que)': $($_.Exception.Message)" 'err'
        }
    }

    $manPath = Join-Path $destino 'manifiesto.json'
    ConvertTo-Json -InputObject @($manifiesto) -Depth 6 | Set-Content $manPath -Encoding UTF8
    Write-Log "=== LISTO: $ok neutralizado(s), $fallo con error ===" 'title'
    Write-Log "Cuarentena guardada en: $destino" 'info'
    if ($ok -gt 0) {
        Write-Log 'AHORA SI: reinicia la PC, y RECIEN DESPUES cambia la contrasena de Discord desde el celular. Toca "Guia de la cuenta".' 'title'
    }
    Invoke-Escaneo
}

function Restore-Cuarentena {
    if (-not (Test-Path $QuarDir)) {
        Write-Log 'No hay cuarentenas guardadas.' 'warn'
        return
    }
    $carpetas = @(Get-ChildItem $QuarDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($carpetas.Count -eq 0) {
        Write-Log 'No hay cuarentenas guardadas.' 'warn'
        return
    }
    $ultima = $carpetas[0]
    $manPath = Join-Path $ultima.FullName 'manifiesto.json'
    if (-not (Test-Path $manPath)) {
        Write-Log "La cuarentena $($ultima.Name) no tiene manifiesto." 'err'
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Voy a deshacer la limpieza del $($ultima.Name), devolviendo todo a donde estaba.`n`nUsalo solo si algo que necesitabas dejo de funcionar.`n`n¿Sigo?",
        'Booster Rescate', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }

    Write-Log "=== RESTAURANDO cuarentena $($ultima.Name) ===" 'title'
    foreach ($e in @(Get-Content $manPath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        try {
            switch ($e.Kind) {
                'file'    { Move-Item -LiteralPath $e.Backup -Destination $e.Path -Force; Write-Log "Devuelto: $($e.Path)" 'ok' }
                'discord' { Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Force; Write-Log "index.js de Discord restaurado al estado previo." 'ok' }
                'hosts'   { Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Force; Write-Log 'hosts restaurado.' 'ok' }
                'run'     { Set-ItemProperty -Path $e.Hive -Name $e.Name -Value $e.Value; Write-Log "Autoarranque devuelto: $($e.Name)" 'ok' }
                'task'    { Register-ScheduledTask -Xml (Get-Content $e.Backup -Raw) -TaskName $e.Name -TaskPath $e.Path -Force | Out-Null; Write-Log "Tarea devuelta: $($e.Name)" 'ok' }
                'defender-excl' { Add-MpPreference -ExclusionPath $e.Path; Write-Log "Exclusion de Defender devuelta: $($e.Path)" 'ok' }
                'defender-rt'   { Write-Log 'La proteccion en tiempo real queda ENCENDIDA a proposito (no se revierte).' 'warn' }
                'wmi'           { Write-Log "La persistencia WMI '$($e.Name)' no se restaura automaticamente." 'warn' }
            }
        } catch {
            Write-Log "No pude restaurar $($e.Kind): $($_.Exception.Message)" 'err'
        }
    }
    Write-Log '=== Restauracion terminada ===' 'title'
}

function Start-DefenderScan {
    Write-Log 'Lanzando escaneo rapido de Microsoft Defender en segundo plano...' 'title'
    try {
        Start-Job -ScriptBlock { Start-MpScan -ScanType QuickScan } | Out-Null
        Write-Log 'Escaneo rapido en marcha (mira el progreso en Seguridad de Windows).' 'ok'
        Write-Log 'Para infecciones jodidas conviene el "Examen sin conexion de Microsoft Defender": reinicia y escanea antes de que arranque Windows.' 'info'
    } catch {
        Write-Log "No pude lanzar el escaneo de Defender: $($_.Exception.Message)" 'err'
    }
}

function Show-GuiaCuenta {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Booster Rescate - Recuperar la cuenta de Discord'
    $dlg.Size            = New-Object System.Drawing.Size(760, 660)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colBg
    $dlg.ForeColor       = $colText

    $txt = New-Object System.Windows.Forms.RichTextBox
    $txt.Location    = New-Object System.Drawing.Point(18, 18)
    $txt.Size        = New-Object System.Drawing.Size(710, 550)
    $txt.ReadOnly    = $true
    $txt.BackColor   = $colPanel
    $txt.ForeColor   = $colText
    $txt.BorderStyle = 'None'
    $txt.Font        = New-Object System.Drawing.Font('Segoe UI', 10)
    $txt.Text = @"
POR QUE PASA ESTO

No le "hackearon la contrasena": le robaron el TOKEN de sesion de Discord.
El token es la llave que prueba que ya inicio sesion, asi que el atacante
entra sin contrasena y sin que el 2FA lo frene. Por eso la cuenta manda
mensajes sola aunque el 2FA este activado.

Cambiar la contrasena INVALIDA todos los tokens. Ese es el corte real.

EL ORDEN IMPORTA (no lo saltees)

1. Cerrar Discord del todo (incluido el icono al lado del reloj).

2. Limpiar la PC PRIMERO: escaneo de esta herramienta + escaneo de
   Microsoft Defender. Si cambias la contrasena con el ladron todavia
   corriendo, se roba el token nuevo y volves al principio.

3. Reiniciar la PC.

4. Cambiar la contrasena DESDE OTRO DISPOSITIVO limpio (el celular).
   Discord: Ajustes > Mi cuenta > Cambiar contrasena.
   Marcar la opcion de cerrar sesion en todos los dispositivos.
   Contrasena nueva y unica: si la repetia en el mail, cambiala ahi tambien.

5. Activar el 2FA (si ya estaba, desactivarlo y volver a activarlo para
   regenerar los codigos de respaldo).

6. Ajustes > Aplicaciones autorizadas: sacar todo lo que no reconozca.
   Ahi suelen quedar bots que siguen posteando aunque cambies la clave.

7. Ajustes > Dispositivos: cerrar todas las sesiones que no sean la suya.

8. Avisar en los servidores donde spameo, para que nadie entre al link.
   Los moderadores pueden borrar los mensajes en masa.

SI EL ESCANEO NO ENCONTRO NADA

Es probable que el token se lo hayan sacado sin infectar la PC: paginas
truchas de "Nitro gratis", QR falsos para escanear con la app, o un
"cheat"/"crackeo" ejecutado una sola vez. Los pasos 4 a 8 siguen siendo
exactamente lo que hay que hacer.

LO QUE NO HAY QUE HACER

- No entrar ni "verificar" nada en el sitio del casino de MrBeast.
- Si alguien deposito plata ahi, no la va a recuperar: es una estafa,
  la pantalla de "retiro exitoso" es dibujada.
- No instalar "el antivirus" que recomienden en esos mismos mensajes.
- No escanear QR de Discord que mande un tercero: eso ES el robo de token.
"@
    $dlg.Controls.Add($txt)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text         = 'Entendido'
    $btnOk.Location     = New-Object System.Drawing.Point(18, 580)
    $btnOk.Size         = New-Object System.Drawing.Size(710, 38)
    $btnOk.BackColor    = $colAccent
    $btnOk.ForeColor    = $colDark
    $btnOk.FlatStyle    = 'Flat'
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)
    $dlg.AcceptButton = $btnOk
    [void]$dlg.ShowDialog($form)
}

# --- GUI --------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Booster Rescate - Limpieza de robo de token de Discord'
$form.Size            = New-Object System.Drawing.Size(1180, 820)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.BackColor       = $colBg
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9.5)

function Set-Rounded($ctl, [int]$r) {
    $d = $r * 2
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, $d, $d, 180, 90)
    $gp.AddArc(($ctl.Width - $d - 1), 0, $d, $d, 270, 90)
    $gp.AddArc(($ctl.Width - $d - 1), ($ctl.Height - $d - 1), $d, $d, 0, 90)
    $gp.AddArc(0, ($ctl.Height - $d - 1), $d, $d, 90, 90)
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

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'BOOSTER RESCATE'
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $colRed
$lblTitle.Location  = New-Object System.Drawing.Point(24, 10)
$lblTitle.AutoSize  = $true
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = 'Cazador del ladron de tokens de Discord (spam de "MrBeast" / casino cripto)'
$lblSub.ForeColor = $colDim
$lblSub.Location  = New-Object System.Drawing.Point(28, 54)
$lblSub.AutoSize  = $true
$form.Controls.Add($lblSub)

$btnScan = New-Btn 'ESCANEAR' 966 14 174 48 $colRed $colDark
$btnScan.Font = New-Object System.Drawing.Font('Segoe UI', 11.5, [System.Drawing.FontStyle]::Bold)
$btnScan.Add_Click({ Invoke-Escaneo })

$btnGuia = New-Btn 'Guia de la cuenta' 786 14 168 48 $colAccent $colDark
$btnGuia.Add_Click({ Show-GuiaCuenta })

# Aviso fijo: el paso que la gente se saltea
$avisoPanel = New-Object System.Windows.Forms.Panel
$avisoPanel.Location  = New-Object System.Drawing.Point(24, 84)
$avisoPanel.Size      = New-Object System.Drawing.Size(1116, 56)
$avisoPanel.BackColor = $colPanel
Set-Rounded $avisoPanel 10
$form.Controls.Add($avisoPanel)

$lblAviso = New-Object System.Windows.Forms.Label
$lblAviso.Text      = "Limpiar la PC NO alcanza: le robaron el token de sesion, que sigue sirviendo hasta que cambie la contrasena." + [Environment]::NewLine +
                      "Orden correcto:  1) escanear y limpiar aca   2) reiniciar   3) cambiar la contrasena DESDE EL CELULAR   4) cerrar todas las sesiones."
$lblAviso.ForeColor = $colYellow
$lblAviso.Location  = New-Object System.Drawing.Point(16, 8)
$lblAviso.Size      = New-Object System.Drawing.Size(1084, 42)
$avisoPanel.Controls.Add($lblAviso)

$lblRes = New-Object System.Windows.Forms.Label
$lblRes.Text      = 'HALLAZGOS  (destilda lo que reconozcas como tuyo: nada se borra, todo va a cuarentena)'
$lblRes.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblRes.ForeColor = $colDim
$lblRes.Location  = New-Object System.Drawing.Point(24, 152)
$lblRes.AutoSize  = $true
$form.Controls.Add($lblRes)

$lv = New-Object System.Windows.Forms.ListView
$lv.Location      = New-Object System.Drawing.Point(24, 174)
$lv.Size          = New-Object System.Drawing.Size(1116, 420)
$lv.View          = 'Details'
$lv.CheckBoxes    = $true
$lv.FullRowSelect = $true
$lv.BackColor     = $colPanel
$lv.ForeColor     = $colText
$lv.BorderStyle   = 'None'
[void]$lv.Columns.Add('Riesgo', 80)
[void]$lv.Columns.Add('Tipo', 90)
[void]$lv.Columns.Add('Que encontre', 470)
[void]$lv.Columns.Add('Donde', 460)
$form.Controls.Add($lv)

$btnAll = New-Btn 'Tildar todo' 24 606 120 36 $colSurface $colText
$btnAll.Add_Click({
    if ($lv.Items.Count -eq 0) { return }
    $nuevo = @($lv.Items | Where-Object { -not $_.Checked }).Count -gt 0
    foreach ($i in $lv.Items) { $i.Checked = $nuevo }
})

$btnClean = New-Btn 'Limpiar tildados' 152 606 160 36 $colRed $colDark
$btnClean.Add_Click({ Invoke-Limpieza })

$btnDef = New-Btn 'Escaneo de Defender' 320 606 170 36 $colBlue $colDark
$btnDef.Add_Click({ Start-DefenderScan })

$btnRestore = New-Btn 'Restaurar cuarentena' 498 606 170 36 $colSurface $colText
$btnRestore.Add_Click({ Restore-Cuarentena })

$btnQuarDir = New-Btn 'Ver cuarentena' 676 606 140 36 $colSurface $colText
$btnQuarDir.Add_Click({
    if (Test-Path $QuarDir) { Start-Process explorer.exe $QuarDir }
    else { Write-Log 'Todavia no hay nada en cuarentena.' 'info' }
})

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text      = 'REGISTRO'
$lblLog.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$lblLog.ForeColor = $colDim
$lblLog.Location  = New-Object System.Drawing.Point(24, 652)
$lblLog.AutoSize  = $true
$form.Controls.Add($lblLog)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(24, 674)
$logBox.Size        = New-Object System.Drawing.Size(1116, 100)
$logBox.ReadOnly    = $true
$logBox.BackColor   = $colPanel
$logBox.ForeColor   = $colText
$logBox.BorderStyle = 'None'
$logBox.Font        = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)
$script:LogBox = $logBox

$form.Add_Shown({
    Write-Log 'Booster Rescate listo. Toca ESCANEAR.' 'title'
    Write-Log 'Busco: cliente de Discord parcheado, autoarranques sin firma, tareas raras, exclusiones de Defender, webhooks escondidos en archivos, hosts tocado y persistencia WMI.' 'info'
    Write-Log 'No soy un antivirus completo: cuando termine, corre igual el escaneo de Defender.' 'warn'
})

[void]$form.ShowDialog()
