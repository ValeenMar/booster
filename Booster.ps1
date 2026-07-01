# ============================================================
#  BOOSTER v2 - Optimizador gaming para despues del trabajo
#  - Listas con comodines (Adobe* cierra todo lo de Adobe)
#  - Barrido de procesos de fondo sin ventana
#  - Pausa servicios de Windows Y de terceros (updaters, etc.)
#  - Protege anticheats, drivers de GPU/audio/perifericos
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

# --- Configuración -------------------------------------------
$script:Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $Dir 'config.json'
$script:StatePath  = Join-Path $Dir '.booster_state.json'

# Todas las listas de procesos/servicios aceptan comodines: 'Adobe*'
$defaultConfig = [ordered]@{
    cerrarSiempre       = @('OneDrive','Teams','ms-teams','Slack','Zoom','Skype','Dropbox','GoogleDriveFS','Adobe*','Acro*','CCX*','Creative Cloud*','CoreSync','Copilot','Widgets','PhoneExperienceHost','YourPhone')
    preguntarAntes      = @('chrome','msedge','firefox','brave','opera','Discord','Spotify','WhatsApp','Telegram','steam','EpicGamesLauncher','Battle.net','RiotClient*','GalaxyClient*','Parsec')
    serviciosPausables  = @('SysMain','WSearch','DiagTrack','Spooler')
    serviciosTercerosAuto = @('Adobe*','AGSService','AGMService','*Update*','*update*','gupdate*','edgeupdate*','Bonjour*','TeamViewer*','AnyDesk*','SQLWriter','ClickToRunSvc')
    serviciosProtegidos = @('WinDefend','WdNisSvc','MDCoreSvc','Sense','*Defender*','Nv*','NVDisplay*','AMD*','Rtk*','Realtek*','*Audio*','vgc','vgk','EasyAntiCheat*','BEService*','FACEIT*','ESEA*','ExitLag*','Cowork*','Claude*')
    protegidos          = @('explorer','dwm','csrss','winlogon','services','lsass','svchost','System','Idle','Registry','smss','wininit','fontdrvhost','sihost','ctfmon','conhost','RuntimeBroker','ShellExperienceHost','StartMenuExperienceHost','SearchHost','TextInputHost','ApplicationFrameHost','SecurityHealth*','MsMpEng','NisSrv','audiodg','taskhostw','WmiPrvSE','dllhost','powershell','pwsh','WindowsTerminal','cmd','OpenConsole','msedgewebview2','claude*','Cowork*','nv*','NVIDIA*','amd*','Radeon*','Rtk*','Realtek*','lghub*','Logi*','Razer*','iCUE*','Corsair*','SteelSeries*','EasyAntiCheat*','BEService*','vgc','vgk','vgtray','vanguard*','FACEIT*','ExitLag*')
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

function Add-StoppedToState([string[]]$names) {
    $previos = @()
    if (Test-Path $StatePath) {
        try { $previos = @(Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    $union = @($previos + $names | Select-Object -Unique)
    ConvertTo-Json -InputObject $union | Set-Content $StatePath -Encoding UTF8
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
    $lista = @($Config.serviciosPausables)
    if (Test-Path $StatePath) {
        try { $lista += @(Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
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
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
    Refresh-ServiceList
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

function Invoke-GamingMode {
    Write-Log '=== MODO GAMING ACTIVADO ===' 'title'
    $ramAntes = Get-FreeRamMB

    # 1) Cierre automático de la lista segura (con comodines)
    $auto = @(Get-RunningMatches $Config.cerrarSiempre)
    foreach ($g in $auto) { Close-ProcessByName $g.Name }
    if ($auto.Count -eq 0) { Write-Log 'Nada que cerrar de la lista automática.' 'info' }

    # 2) Modo mixto: apps conocidas + barrido de procesos de fondo
    $ask   = @(Get-RunningMatches $Config.preguntarAntes | ForEach-Object { $_ | Add-Member Tipo 'App' -PassThru })
    $fondo = @(Get-BackgroundApps | ForEach-Object { $_ | Add-Member Tipo 'Fondo' -PassThru })
    $items = @($ask + $fondo | Sort-Object RamMB -Descending)
    if ($items.Count -gt 0) {
        $elegidos = Show-KillPicker $items
        foreach ($name in $elegidos) { Close-ProcessByName $name }
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

    Start-Sleep -Milliseconds 1500
    $ramDespues = Get-FreeRamMB
    $ganancia = $ramDespues - $ramAntes
    Write-Log ("=== LISTO. RAM libre: {0:N0} MB -> {1:N0} MB ({2}{3:N0} MB) ===" -f $ramAntes, $ramDespues, $(if ($ganancia -ge 0) { '+' } else { '' }), $ganancia) 'title'

    Refresh-ServiceList
    Refresh-ProcessList
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
    if (Test-Path $StatePath) {
        try {
            foreach ($svcName in @(Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($agregados.ContainsKey($svcName)) { continue }
                $item = New-Object System.Windows.Forms.ListViewItem($svcName)
                [void]$item.SubItems.Add('Pausado')
                [void]$item.SubItems.Add('Terceros')
                $item.ForeColor = $colDim
                [void]$lvSvc.Items.Add($item)
            }
        } catch {}
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
    Write-Log 'Booster v2 listo. Tocá MODO GAMING o revisá las listas.' 'title'
    Refresh-ServiceList
    Refresh-ProcessList
})

[void]$form.ShowDialog()
