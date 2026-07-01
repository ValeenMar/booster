# ============================================================
#  BOOSTER - Optimizador gaming para despues del trabajo
#  Cierra apps en segundo plano, pausa servicios pesados y
#  muestra los procesos que mas RAM/CPU consumen.
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
$script:Dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $Dir 'config.json'
$script:StatePath  = Join-Path $Dir '.booster_state.json'

$defaultConfig = [ordered]@{
    cerrarSiempre      = @('OneDrive','Teams','ms-teams','Slack','Zoom','Skype','Dropbox','GoogleDriveFS','CCXProcess','AdobeCollabSync','Creative Cloud','Copilot','Widgets','PhoneExperienceHost','YourPhone')
    preguntarAntes     = @('chrome','msedge','firefox','brave','opera','Discord','Spotify','WhatsApp','Telegram','steam','EpicGamesLauncher','Battle.net','RiotClientServices','GalaxyClient')
    serviciosPausables = @('SysMain','WSearch','DiagTrack','Spooler')
    protegidos         = @('explorer','dwm','csrss','winlogon','services','lsass','svchost','System','Idle','Registry','smss','wininit','fontdrvhost','sihost','ctfmon','conhost','RuntimeBroker','ShellExperienceHost','StartMenuExperienceHost','SearchHost','TextInputHost','ApplicationFrameHost','SecurityHealthService','MsMpEng','NisSrv','audiodg','taskhostw','WmiPrvSE','dllhost','powershell','pwsh','WindowsTerminal','msedgewebview2')
    umbralRamMB        = 150
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

# --- Paleta de colores ---------------------------------------
$colBg      = [System.Drawing.Color]::FromArgb(20, 20, 31)
$colPanel   = [System.Drawing.Color]::FromArgb(30, 30, 46)
$colAccent  = [System.Drawing.Color]::FromArgb(137, 90, 246)
$colGreen   = [System.Drawing.Color]::FromArgb(94, 200, 120)
$colRed     = [System.Drawing.Color]::FromArgb(230, 90, 100)
$colText    = [System.Drawing.Color]::FromArgb(225, 225, 235)
$colDim     = [System.Drawing.Color]::FromArgb(140, 140, 160)

# --- Helpers de lógica ----------------------------------------
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
        if ($Config.protegidos -contains $p.Name) { continue }
        $cpuMs = 0
        try {
            if ($t1.ContainsKey($p.Id)) { $cpuMs = $p.TotalProcessorTime.TotalMilliseconds - $t1[$p.Id] }
        } catch {}
        if (-not $grupos.ContainsKey($p.Name)) {
            $grupos[$p.Name] = [pscustomobject]@{ Name = $p.Name; Count = 0; RamMB = 0.0; CpuMs = 0.0 }
        }
        $g = $grupos[$p.Name]
        $g.Count++
        $g.RamMB += $p.WorkingSet64 / 1MB
        $g.CpuMs += [Math]::Max(0, $cpuMs)
    }
    $cores = [Environment]::ProcessorCount
    foreach ($g in $grupos.Values) {
        $g | Add-Member -NotePropertyName CpuPct -NotePropertyValue ([Math]::Round($g.CpuMs / 900 / $cores * 100, 1))
    }
    $grupos.Values | Where-Object { $_.RamMB -ge $Config.umbralRamMB -or $_.CpuPct -ge 3 } | Sort-Object RamMB -Descending
}

function Close-ProcessByName([string]$name) {
    if ($Config.protegidos -contains $name) {
        Write-Log "Ignorado (protegido): $name" 'warn'
        return
    }
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $ram = [Math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
    Write-Log "Cerrado: $name (liberados ~$ram MB)" 'ok'
}

function Stop-HeavyServices {
    $detenidos = @()
    foreach ($svcName in $Config.serviciosPausables) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                $detenidos += $svcName
                Write-Log "Servicio pausado: $svcName ($($svc.DisplayName))" 'ok'
            } catch {
                Write-Log "No se pudo pausar el servicio $svcName" 'err'
            }
        }
    }
    if ($detenidos.Count -gt 0) {
        ConvertTo-Json -InputObject @($detenidos) | Set-Content $StatePath -Encoding UTF8
    } else {
        Write-Log 'No hay servicios pausables corriendo.' 'info'
    }
    Refresh-ServiceList
}

function Restore-Services {
    $lista = if (Test-Path $StatePath) {
        @(Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } else {
        @($Config.serviciosPausables)
    }
    foreach ($svcName in $lista) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                Write-Log "Servicio restaurado: $svcName" 'ok'
            } catch {
                Write-Log "No se pudo iniciar el servicio $svcName" 'err'
            }
        }
    }
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
    Refresh-ServiceList
}

function Show-KillPicker([string[]]$names) {
    # Dialogo del "modo mixto": muestra las apps de la lista
    # 'preguntarAntes' que estan corriendo y deja elegir cuales cerrar.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Booster - Confirmar cierre'
    $dlg.Size            = New-Object System.Drawing.Size(420, 420)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $colBg
    $dlg.ForeColor       = $colText

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Estas apps también están abiertas.`nDestildá las que quieras dejar corriendo:"
    $lbl.Location = New-Object System.Drawing.Point(15, 12)
    $lbl.Size     = New-Object System.Drawing.Size(380, 36)
    $dlg.Controls.Add($lbl)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location     = New-Object System.Drawing.Point(15, 55)
    $clb.Size         = New-Object System.Drawing.Size(375, 260)
    $clb.CheckOnClick = $true
    $clb.BackColor    = $colPanel
    $clb.ForeColor    = $colText
    $clb.BorderStyle  = 'FixedSingle'
    foreach ($n in $names) { [void]$clb.Items.Add($n, $true) }
    $dlg.Controls.Add($clb)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text         = 'Cerrar seleccionadas'
    $btnOk.Location     = New-Object System.Drawing.Point(15, 330)
    $btnOk.Size         = New-Object System.Drawing.Size(185, 34)
    $btnOk.BackColor    = $colAccent
    $btnOk.ForeColor    = [System.Drawing.Color]::White
    $btnOk.FlatStyle    = 'Flat'
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'No cerrar ninguna'
    $btnCancel.Location     = New-Object System.Drawing.Point(210, 330)
    $btnCancel.Size         = New-Object System.Drawing.Size(180, 34)
    $btnCancel.BackColor    = $colPanel
    $btnCancel.ForeColor    = $colText
    $btnCancel.FlatStyle    = 'Flat'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        return @($clb.CheckedItems)
    }
    return @()
}

function Invoke-GamingMode {
    Write-Log '=== MODO GAMING ACTIVADO ===' 'title'

    # 1) Cierre automático de la lista segura
    $cerradas = 0
    foreach ($name in $Config.cerrarSiempre) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            Close-ProcessByName $name
            $cerradas++
        }
    }
    if ($cerradas -eq 0) { Write-Log 'Nada que cerrar de la lista automática.' 'info' }

    # 2) Modo mixto: preguntar por el resto
    $corriendo = @($Config.preguntarAntes | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    if ($corriendo.Count -gt 0) {
        $elegidas = Show-KillPicker $corriendo
        foreach ($name in $elegidas) { Close-ProcessByName $name }
    }

    # 3) Pausar servicios pesados
    Stop-HeavyServices

    Write-Log '=== LISTO. A jugar sin lag ===' 'title'
    Refresh-ProcessList
}

# --- GUI -------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Booster - Optimizador gaming'
$form.Size            = New-Object System.Drawing.Size(960, 700)
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
$btnGaming.Location  = New-Object System.Drawing.Point(680, 15)
$btnGaming.Size      = New-Object System.Drawing.Size(240, 58)
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
[void]$lvProc.Columns.Add('Proceso', 220)
[void]$lvProc.Columns.Add('Instancias', 80)
[void]$lvProc.Columns.Add('RAM (MB)', 110)
[void]$lvProc.Columns.Add('CPU (%)', 90)
$form.Controls.Add($lvProc)

function Refresh-ProcessList {
    $form.Cursor = 'WaitCursor'
    $lvProc.Items.Clear()
    foreach ($g in (Get-ProcessSnapshot)) {
        $item = New-Object System.Windows.Forms.ListViewItem($g.Name)
        [void]$item.SubItems.Add([string]$g.Count)
        [void]$item.SubItems.Add(([Math]::Round($g.RamMB)).ToString('N0'))
        [void]$item.SubItems.Add([string]$g.CpuPct)
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
$lblSvc.Text      = 'Servicios pesados (se restauran al reiniciar o con el botón)'
$lblSvc.ForeColor = $colText
$lblSvc.Location  = New-Object System.Drawing.Point(620, 90)
$lblSvc.AutoSize  = $true
$form.Controls.Add($lblSvc)

$lvSvc = New-Object System.Windows.Forms.ListView
$lvSvc.Location      = New-Object System.Drawing.Point(620, 115)
$lvSvc.Size          = New-Object System.Drawing.Size(300, 300)
$lvSvc.View          = 'Details'
$lvSvc.FullRowSelect = $true
$lvSvc.BackColor     = $colPanel
$lvSvc.ForeColor     = $colText
$lvSvc.BorderStyle   = 'FixedSingle'
[void]$lvSvc.Columns.Add('Servicio', 180)
[void]$lvSvc.Columns.Add('Estado', 95)
$form.Controls.Add($lvSvc)

function Refresh-ServiceList {
    $lvSvc.Items.Clear()
    foreach ($svcName in $Config.serviciosPausables) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $estado = if (-not $svc) { 'No existe' } elseif ($svc.Status -eq 'Running') { 'Corriendo' } else { 'Pausado' }
        $item = New-Object System.Windows.Forms.ListViewItem($svcName)
        [void]$item.SubItems.Add($estado)
        $item.ForeColor = if ($estado -eq 'Corriendo') { $colGreen } else { $colDim }
        [void]$lvSvc.Items.Add($item)
    }
}

$btnSvcStop = New-Object System.Windows.Forms.Button
$btnSvcStop.Text      = 'Pausar servicios'
$btnSvcStop.Location  = New-Object System.Drawing.Point(620, 425)
$btnSvcStop.Size      = New-Object System.Drawing.Size(145, 34)
$btnSvcStop.BackColor = $colPanel
$btnSvcStop.ForeColor = $colText
$btnSvcStop.FlatStyle = 'Flat'
$btnSvcStop.Add_Click({ Stop-HeavyServices })
$form.Controls.Add($btnSvcStop)

$btnSvcStart = New-Object System.Windows.Forms.Button
$btnSvcStart.Text      = 'Restaurar servicios'
$btnSvcStart.Location  = New-Object System.Drawing.Point(772, 425)
$btnSvcStart.Size      = New-Object System.Drawing.Size(148, 34)
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
$logBox.Size        = New-Object System.Drawing.Size(900, 115)
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
    Write-Log 'Booster listo. Tocá MODO GAMING o revisá la lista de procesos.' 'title'
    Refresh-ServiceList
    Refresh-ProcessList
})

[void]$form.ShowDialog()
