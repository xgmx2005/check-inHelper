param(
  [string]$SettingsPath = (Join-Path $PSScriptRoot "..\config\tray-settings.json"),
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\checkin-sites.json"),
  [string]$AgentScriptPath = (Join-Path $PSScriptRoot "run-agent-checkin.ps1"),
  [string]$MailScriptPath = (Join-Path $PSScriptRoot "send_reminder_email.py"),
  [string]$ReportsDir = (Join-Path $PSScriptRoot "..\reports"),
  [string]$Python = "python",
  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:CheckinRunning = $false # checkin-running-state
$script:CheckinJob = $null
$script:ActiveGeneratedConfigPath = $null
$script:LastStatus = "Idle"
$script:Settings = $null
$script:NotifyIcon = $null
$script:RunNowMenuItem = $null
$script:SettingsForm = $null
$script:SettingsWindowProgrammaticClose = $false

function Get-RepositoryRoot {
  (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-StartupShortcutPath {
  $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
  Join-Path $startup "bb-browser-checkin-tray.lnk"
}

function Test-StartupShortcut {
  Test-Path -Path (Get-StartupShortcutPath)
}

function Set-StartupShortcut {
  param([bool]$Enabled)

  $shortcutPath = Get-StartupShortcutPath
  if (-not $Enabled) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    return
  }

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = (Get-Command powershell.exe -ErrorAction Stop).Source
  $scriptPath = (Resolve-Path -Path $PSCommandPath).Path
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
  $shortcut.WorkingDirectory = Get-RepositoryRoot
  $shortcut.IconLocation = "$([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName),0"
  $shortcut.Save()
}

function Get-CheckinConfig {
  Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-DefaultSettings {
  $config = Get-CheckinConfig
  $siteSettings = [ordered]@{}
  foreach ($site in $config.sites) {
    $isManual = ($site.PSObject.Properties.Name -contains "manualReminderOnly") -and [bool]$site.manualReminderOnly
    $siteSettings[$site.name] = [ordered]@{
      enabled = $true
      manualReminderOnly = $isManual
    }
  }

  [pscustomobject]@{
    dailyRunTime = "10:00"
    startWithWindows = $false
    keepReports = $false
    lastScheduledRunDate = ""
    sites = [pscustomobject]$siteSettings
  }
}

function Copy-SettingValue {
  param(
    [object]$Target,
    [object]$Source,
    [string]$Name
  )

  if ($Source -and ($Source.PSObject.Properties.Name -contains $Name)) {
    $Target.$Name = $Source.$Name
  }
}

function Merge-Settings {
  param([object]$Loaded)

  $defaults = Get-DefaultSettings
  Copy-SettingValue -Target $defaults -Source $Loaded -Name "dailyRunTime"
  Copy-SettingValue -Target $defaults -Source $Loaded -Name "startWithWindows"
  Copy-SettingValue -Target $defaults -Source $Loaded -Name "keepReports"
  Copy-SettingValue -Target $defaults -Source $Loaded -Name "lastScheduledRunDate"

  foreach ($siteName in @($defaults.sites.PSObject.Properties.Name)) {
    $loadedSite = $null
    if ($Loaded -and $Loaded.sites -and ($Loaded.sites.PSObject.Properties.Name -contains $siteName)) {
      $loadedSite = $Loaded.sites.PSObject.Properties[$siteName].Value
    }
    if ($loadedSite) {
      Copy-SettingValue -Target $defaults.sites.$siteName -Source $loadedSite -Name "enabled"
      Copy-SettingValue -Target $defaults.sites.$siteName -Source $loadedSite -Name "manualReminderOnly"
    }
  }

  $defaults.startWithWindows = Test-StartupShortcut
  $defaults
}

function Save-Settings {
  param([object]$Settings)

  $settingsDir = Split-Path -Parent $SettingsPath
  if (-not (Test-Path -Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
  }
  $Settings | ConvertTo-Json -Depth 8 | Set-Content -Path $SettingsPath -Encoding UTF8
}

function Load-Settings {
  $loaded = $null
  if (Test-Path -Path $SettingsPath) {
    $loaded = Get-Content -Path $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  }

  $settings = Merge-Settings -Loaded $loaded
  Save-Settings -Settings $settings
  $script:Settings = $settings
  $settings
}

function Get-SettingSite {
  param(
    [object]$Settings,
    [string]$Name
  )

  if ($Settings.sites.PSObject.Properties.Name -contains $Name) {
    return $Settings.sites.PSObject.Properties[$Name].Value
  }

  $null
}

function Set-OrAddProperty {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Value
  )

  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  }
  else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-EffectiveConfigFile {
  param([object]$Settings)

  $config = Get-CheckinConfig
  $sites = New-Object System.Collections.Generic.List[object]
  foreach ($site in $config.sites) {
    $siteSetting = Get-SettingSite -Settings $Settings -Name $site.name
    if ($siteSetting -and -not [bool]$siteSetting.enabled) {
      continue
    }
    if ($siteSetting) {
      Set-OrAddProperty -Object $site -Name "manualReminderOnly" -Value ([bool]$siteSetting.manualReminderOnly)
    }
    $sites.Add($site)
  }
  $config.sites = $sites.ToArray()

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "bb-browser-checkin-tray"
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $tempPath = Join-Path $tempRoot "effective-checkin-sites.json"
  $config | ConvertTo-Json -Depth 8 | Set-Content -Path $tempPath -Encoding UTF8
  $tempPath
}

function Get-SmtpStatusText {
  $vars = @("CHECKIN_MAIL_TO", "CHECKIN_SMTP_HOST", "CHECKIN_SMTP_PORT", "CHECKIN_SMTP_USER", "CHECKIN_SMTP_PASS", "CHECKIN_MAIL_FROM")
  $lines = foreach ($name in $vars) {
    $state = if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { "missing" } else { "configured" }
    "${name}: $state"
  }
  $lines -join [Environment]::NewLine
}

function Invoke-PythonUtf8 {
  param([string[]]$Arguments)

  $previousPythonUtf8 = $env:PYTHONUTF8
  $previousPythonIoEncoding = $env:PYTHONIOENCODING
  try {
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $output = & $Python @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
      ExitCode = $exitCode
      Output = ($output | Out-String).Trim()
    }
  }
  finally {
    if ($null -eq $previousPythonUtf8) {
      Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    else {
      $env:PYTHONUTF8 = $previousPythonUtf8
    }

    if ($null -eq $previousPythonIoEncoding) {
      Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
    else {
      $env:PYTHONIOENCODING = $previousPythonIoEncoding
    }
  }
}

function Update-TrayState {
  param([string]$Status)

  $script:LastStatus = $Status
  if ($script:NotifyIcon) {
    $script:NotifyIcon.Text = "bb-browser check-in - $Status"
  }
  if ($script:RunNowMenuItem) {
    $script:RunNowMenuItem.Enabled = -not $script:CheckinRunning
  }
}

function Show-Balloon {
  param(
    [string]$Title,
    [string]$Text,
    [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
  )

  if ($script:NotifyIcon) {
    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText = $Text
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(5000)
  }
}

function Confirm-Action {
  param(
    [string]$Title,
    [string]$Message
  )

  $result = [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function New-UiFont {
  param(
    [float]$Size,
    [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
  )
  New-Object System.Drawing.Font("Microsoft YaHei UI", $Size, $Style)
}

function New-UiColor {
  param(
    [int]$R,
    [int]$G,
    [int]$B
  )
  [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function New-CardPanel {
  param(
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height,
    [System.Drawing.Color]$BackColor = (New-UiColor -R 248 -G 249 -B 252)
  )

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($X, $Y)
  $panel.Size = New-Object System.Drawing.Size($Width, $Height)
  $panel.BackColor = $BackColor
  $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $panel
}

function New-SectionLabel {
  param(
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width = 220
  )

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, 24)
  $label.Font = New-UiFont -Size 10.5 -Style ([System.Drawing.FontStyle]::Bold)
  $label.ForeColor = [System.Drawing.Color]::FromArgb(88, 94, 107)
  $label
}

function New-CatMascotLabel {
  param(
    [int]$X,
    [int]$Y,
    [int]$Width = 260
  )

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "小猫助手  ᓚᘏᗢ"
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, 42)
  $label.Font = New-UiFont -Size 15 -Style ([System.Drawing.FontStyle]::Bold)
  $label.ForeColor = New-UiColor -R 62 -G 71 -B 63
  $label.BackColor = [System.Drawing.Color]::Transparent
  $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $label
}

function New-StatusSummaryCard {
  param(
    [string]$Title,
    [string]$Value,
    [string]$Tone,
    [int]$X,
    [int]$Y
  )

  $backColor = if ($Tone -eq "attention") {
    New-UiColor -R 255 -G 245 -B 239
  }
  elseif ($Tone -eq "mail") {
    New-UiColor -R 241 -G 248 -B 244
  }
  else {
    New-UiColor -R 246 -G 249 -B 247
  }

  $accentColor = if ($Tone -eq "attention") {
    New-UiColor -R 206 -G 102 -B 72
  }
  elseif ($Tone -eq "mail") {
    New-UiColor -R 95 -G 137 -B 109
  }
  else {
    New-UiColor -R 103 -G 126 -B 112
  }

  $card = New-CardPanel -X $X -Y $Y -Width 168 -Height 78 -BackColor $backColor

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = $Title
  $titleLabel.Location = New-Object System.Drawing.Point(18, 12)
  $titleLabel.Size = New-Object System.Drawing.Size(132, 20)
  $titleLabel.Font = New-UiFont -Size 8.8
  $titleLabel.ForeColor = New-UiColor -R 104 -G 108 -B 103
  $card.Controls.Add($titleLabel)

  $valueLabel = New-Object System.Windows.Forms.Label
  $valueLabel.Text = $Value
  $valueLabel.Location = New-Object System.Drawing.Point(18, 34)
  $valueLabel.Size = New-Object System.Drawing.Size(132, 28)
  $valueLabel.Font = New-UiFont -Size 13.5 -Style ([System.Drawing.FontStyle]::Bold)
  $valueLabel.ForeColor = $accentColor
  $card.Controls.Add($valueLabel)

  $card
}

function New-PawStatusLabel {
  param(
    [string]$Text,
    [bool]$Attention = $false
  )

  $label = New-Object System.Windows.Forms.Label
  # paw-status-marker
  $label.Text = if ($Attention) { "!  $Text" } else { ".  $Text" }
  $label.Font = New-UiFont -Size 9.2 -Style ([System.Drawing.FontStyle]::Bold)
  $label.ForeColor = if ($Attention) { New-UiColor -R 185 -G 88 -B 62 } else { New-UiColor -R 83 -G 124 -B 91 }
  $label.Size = New-Object System.Drawing.Size(178, 24)
  $label
}

function New-SidebarItem {
  param(
    [string]$Text,
    [int]$Y,
    [bool]$Active = $false
  )

  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point(14, $Y)
  $button.Size = New-Object System.Drawing.Size(246, 42)
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 0
  $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $button.Font = New-UiFont -Size 10
  $button.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  if ($Active) {
    $button.BackColor = New-UiColor -R 255 -G 255 -B 252
    $button.ForeColor = New-UiColor -R 39 -G 45 -B 42
  }
  else {
    $button.BackColor = New-UiColor -R 237 -G 240 -B 235
    $button.ForeColor = New-UiColor -R 91 -G 98 -B 92
  }
  $button
}

function Close-TrayApp {
  if ($script:NotifyIcon) {
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
  }
  [System.Windows.Forms.Application]::Exit()
}

function Start-Checkin {
  param(
    [string]$Reason = "manual"
  )

  if ($script:CheckinRunning) {
    Show-Balloon -Title "Check-in already running" -Text "Wait for the current run to finish."
    return
  }

  $settings = Load-Settings
  $effectiveConfig = New-EffectiveConfigFile -Settings $settings
  $script:ActiveGeneratedConfigPath = $effectiveConfig

  $today = (Get-Date).ToString("yyyy-MM-dd")
  $settings.lastScheduledRunDate = $today
  Save-Settings -Settings $settings

  $keepReports = [bool]$settings.keepReports
  $script:CheckinRunning = $true
  Update-TrayState -Status "Running"
  Show-Balloon -Title "Check-in started" -Text "bb-browser check-in is running."

  $script:CheckinJob = Start-Job -ScriptBlock {
    param($AgentScript, $ConfigPathArg, $ReportsDirArg, $PythonArg, $KeepReportsArg)

    $args = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      $AgentScript,
      "-ConfigPath",
      $ConfigPathArg,
      "-ReportsDir",
      $ReportsDirArg,
      "-Python",
      $PythonArg
    )
    if ($KeepReportsArg) {
      $args += "-KeepReports"
    }

    $output = & powershell @args 2>&1
    [pscustomobject]@{
      ExitCode = $LASTEXITCODE
      Output = ($output | Out-String).Trim()
    }
  } -ArgumentList $AgentScriptPath, $effectiveConfig, $ReportsDir, $Python, $keepReports
}

function Complete-CheckinJob {
  if (-not $script:CheckinRunning -or -not $script:CheckinJob) {
    return
  }
  if ($script:CheckinJob.State -notin @("Completed", "Failed", "Stopped")) {
    return
  }

  $result = Receive-Job -Job $script:CheckinJob -ErrorAction SilentlyContinue | Select-Object -Last 1
  Remove-Job -Job $script:CheckinJob -Force -ErrorAction SilentlyContinue
  $script:CheckinJob = $null
  $script:CheckinRunning = $false

  if ($script:ActiveGeneratedConfigPath) {
    Remove-Item -LiteralPath $script:ActiveGeneratedConfigPath -Force -ErrorAction SilentlyContinue
    $script:ActiveGeneratedConfigPath = $null
  }

  if ($result -and $result.ExitCode -eq 0) {
    Update-TrayState -Status "Completed"
    Show-Balloon -Title "Check-in completed" -Text "Summary email path finished. Local reports were cleaned unless debug retention is enabled."
  }
  else {
    Update-TrayState -Status "Failed"
    $message = if ($result) { $result.Output } else { "Check-in job did not return a result." }
    if ($message.Length -gt 180) {
      $message = $message.Substring(0, 180) + "..."
    }
    Show-Balloon -Title "Check-in failed" -Text $message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
  }
}

function Test-DailySchedule {
  if ($script:CheckinRunning) {
    return
  }

  $settings = Load-Settings
  $runTime = [datetime]::ParseExact($settings.dailyRunTime, "HH:mm", $null)
  $now = Get-Date
  $scheduledToday = Get-Date -Hour $runTime.Hour -Minute $runTime.Minute -Second 0
  $today = $now.ToString("yyyy-MM-dd")
  if ($now -ge $scheduledToday -and $settings.lastScheduledRunDate -ne $today) {
    Start-Checkin -Reason "scheduled"
  }
}

function Open-LinuxDoLogin {
  Start-Job -ScriptBlock {
    & bb-browser.cmd open "https://linux.do/" 2>&1 | Out-String
  } | Out-Null
  Show-Balloon -Title "Linux.do" -Text "Opening Linux.do in bb-browser."
}

function Cleanup-LocalReports {
  if (-not (Test-Path -Path $ReportsDir)) {
    Show-Balloon -Title "Reports clean" -Text "Reports directory does not exist."
    return
  }

  $resolvedRoot = (Resolve-Path -Path $ReportsDir).Path
  $workspaceRoot = Get-RepositoryRoot
  if (-not $resolvedRoot.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Show-Balloon -Title "Cleanup refused" -Text "Reports directory is outside the workspace." -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
    return
  }

  $directoryCount = 0
  Get-ChildItem -Path $resolvedRoot -Directory | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
    $directoryCount += 1
  }
  $fileCount = 0
  Get-ChildItem -Path $resolvedRoot -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    $fileCount += 1
  }
  Show-Balloon -Title "Reports cleaned" -Text "Removed $directoryCount report directories and $fileCount files."
}

function Send-TestEmail {
  if ($script:CheckinRunning) {
    Show-Balloon -Title "Busy" -Text "Wait for the current check-in run first."
    return
  }

  $testRoot = Join-Path $ReportsDir "tray-email-test"
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $resultPath = Join-Path $testRoot "result.json"
  $items = @(
    [pscustomobject]@{
      name = "linux.do"
      url = "https://linux.do/"
      status = "ok"
      reason = "Tray test message."
      finalUrl = "https://linux.do/"
      title = ""
      screenshot = ""
      timestamp = (Get-Date).ToString("s")
    },
    [pscustomobject]@{
      name = "muyuan"
      url = "https://muyuan.do"
      status = "manual_reminder"
      reason = "Tray test manual reminder."
      finalUrl = "https://muyuan.do"
      title = ""
      screenshot = ""
      timestamp = (Get-Date).ToString("s")
    }
  )
  $items | ConvertTo-Json -Depth 4 | Set-Content -Path $resultPath -Encoding UTF8
  "# Tray test email" | Set-Content -Path (Join-Path $testRoot "result.md") -Encoding UTF8

  try {
    $output = Invoke-PythonUtf8 -Arguments @($MailScriptPath, "--result-json", $resultPath)
    if ($output.ExitCode -eq 0) {
      Show-Balloon -Title "Test email sent" -Text "SMTP test message was sent."
    }
    else {
      $text = ($output.Output | Out-String).Trim()
      if ($text.Length -gt 180) {
        $text = $text.Substring(0, 180) + "..."
      }
      Show-Balloon -Title "Test email failed" -Text $text -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
  }
  finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Show-SettingsWindow {
  if ($script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
    $script:SettingsForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:SettingsForm.Activate()
    return
  }

  $settings = Load-Settings
  $config = Get-CheckinConfig

  $form = New-Object System.Windows.Forms.Form
  $form.Text = "Check-in Helper"
  $form.StartPosition = "CenterScreen"
  $form.Size = New-Object System.Drawing.Size(1180, 780)
  $form.MinimumSize = New-Object System.Drawing.Size(1100, 720)
  $form.BackColor = New-UiColor -R 250 -G 249 -B 245
  $form.Font = New-UiFont -Size 9.5
  $script:SettingsForm = $form

  $sidebarWidth = 286 # layout-sidebar-width
  $contentOriginX = $sidebarWidth # layout-content-origin

  $sidebar = New-Object System.Windows.Forms.Panel
  $sidebar.Location = New-Object System.Drawing.Point(0, 0)
  $sidebar.Size = New-Object System.Drawing.Size($sidebarWidth, $form.ClientSize.Height)
  $sidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $sidebar.BackColor = New-UiColor -R 237 -G 240 -B 235
  $form.Controls.Add($sidebar)

  $brand = New-Object System.Windows.Forms.Label
  $brand.Text = "Check-in Helper"
  $brand.Font = New-UiFont -Size 14 -Style ([System.Drawing.FontStyle]::Bold)
  $brand.ForeColor = New-UiColor -R 38 -G 48 -B 41
  $brand.Location = New-Object System.Drawing.Point(22, 20)
  $brand.Size = New-Object System.Drawing.Size(230, 28)
  $sidebar.Controls.Add($brand)

  $subBrand = New-Object System.Windows.Forms.Label
  $subBrand.Text = "Linux.do OAuth daily helper"
  $subBrand.Font = New-UiFont -Size 8.5
  $subBrand.ForeColor = New-UiColor -R 105 -G 112 -B 103
  $subBrand.Location = New-Object System.Drawing.Point(22, 50)
  $subBrand.Size = New-Object System.Drawing.Size(238, 22)
  $sidebar.Controls.Add($subBrand)

  $sidebar.Controls.Add((New-CatMascotLabel -X 22 -Y 86 -Width 240))
  $sidebar.Controls.Add((New-SidebarItem -Text "通用面板" -Y 146 -Active $true))
  $sidebar.Controls.Add((New-SidebarItem -Text "站点状态" -Y 196))
  $sidebar.Controls.Add((New-SidebarItem -Text "邮件提醒" -Y 246))
  $sidebar.Controls.Add((New-SidebarItem -Text "清理策略" -Y 296))

  $catTip = New-CardPanel -X 18 -Y 366 -Width 248 -Height 126 -BackColor (New-UiColor -R 255 -G 252 -B 246)
  $sidebar.Controls.Add($catTip)

  $catTipTitle = New-Object System.Windows.Forms.Label
  $catTipTitle.Text = "小猫助手"
  $catTipTitle.Font = New-UiFont -Size 10.5 -Style ([System.Drawing.FontStyle]::Bold)
  $catTipTitle.ForeColor = New-UiColor -R 63 -G 72 -B 63
  $catTipTitle.Location = New-Object System.Drawing.Point(18, 14)
  $catTipTitle.Size = New-Object System.Drawing.Size(180, 24)
  $catTip.Controls.Add($catTipTitle)

  $catTipText = New-Object System.Windows.Forms.Label
  $catTipText.Text = "定时巡查、失败提醒、手动站点轻轻拍你一下。"
  $catTipText.Font = New-UiFont -Size 9
  $catTipText.ForeColor = New-UiColor -R 112 -G 116 -B 108
  $catTipText.Location = New-Object System.Drawing.Point(18, 44)
  $catTipText.Size = New-Object System.Drawing.Size(206, 52)
  $catTip.Controls.Add($catTipText)

  $doctor = New-Object System.Windows.Forms.Panel
  $doctor.Location = New-Object System.Drawing.Point(18, 640)
  $doctor.Size = New-Object System.Drawing.Size(252, 48)
  $doctor.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $doctor.BackColor = New-UiColor -R 226 -G 235 -B 226
  $doctor.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $sidebar.Controls.Add($doctor)

  $doctorText = New-Object System.Windows.Forms.Label
  $doctorText.Text = "Doctor    $($script:LastStatus)"
  $doctorText.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
  $doctorText.ForeColor = New-UiColor -R 72 -G 93 -B 73
  $doctorText.Location = New-Object System.Drawing.Point(16, 14)
  $doctorText.Size = New-Object System.Drawing.Size(200, 22)
  $doctor.Controls.Add($doctorText)

  $content = New-Object System.Windows.Forms.Panel
  $content.Location = New-Object System.Drawing.Point($contentOriginX, 0)
  $content.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - $contentOriginX), $form.ClientSize.Height)
  $content.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $content.BackColor = New-UiColor -R 250 -G 249 -B 245
  $form.Controls.Add($content)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = "今日签到"
  $title.Font = New-UiFont -Size 24 -Style ([System.Drawing.FontStyle]::Bold)
  $title.ForeColor = New-UiColor -R 38 -G 45 -B 41
  $title.Location = New-Object System.Drawing.Point(54, 34)
  $title.Size = New-Object System.Drawing.Size(220, 44)
  $content.Controls.Add($title)

  $catHeader = New-CatMascotLabel -X 650 -Y 36 -Width 230
  $content.Controls.Add($catHeader)

  $status = New-Object System.Windows.Forms.Label
  $status.Text = "当前状态：$($script:LastStatus)    下一次按计划运行：$($settings.dailyRunTime)"
  $status.Font = New-UiFont -Size 10
  $status.ForeColor = New-UiColor -R 93 -G 100 -B 92
  $status.Location = New-Object System.Drawing.Point(58, 82)
  $status.Size = New-Object System.Drawing.Size(760, 28)
  $content.Controls.Add($status)

  $content.Controls.Add((New-StatusSummaryCard -Title "站点状态" -Value "全部正常" -Tone "ok" -X 56 -Y 126))
  $content.Controls.Add((New-StatusSummaryCard -Title "手动提醒" -Value "需要处理" -Tone "attention" -X 238 -Y 126))
  $content.Controls.Add((New-StatusSummaryCard -Title "邮件提醒" -Value "HTML SMTP" -Tone "mail" -X 420 -Y 126))
  $content.Controls.Add((New-StatusSummaryCard -Title "计划任务" -Value $settings.dailyRunTime -Tone "ok" -X 602 -Y 126))

  $content.Controls.Add((New-SectionLabel -Text "计划任务" -X 58 -Y 226))

  $planCard = New-CardPanel -X 56 -Y 256 -Width 790 -Height 122 -BackColor (New-UiColor -R 255 -G 252 -B 247)
  $content.Controls.Add($planCard)

  $timeLabel = New-Object System.Windows.Forms.Label
  $timeLabel.Text = "每日自动签到"
  $timeLabel.Font = New-UiFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
  $timeLabel.Location = New-Object System.Drawing.Point(24, 24)
  $timeLabel.Size = New-Object System.Drawing.Size(180, 24)
  $planCard.Controls.Add($timeLabel)

  $timeHelp = New-Object System.Windows.Forms.Label
  $timeHelp.Text = "托盘启动后，小猫助手会在这个时间巡查一次。"
  $timeHelp.ForeColor = New-UiColor -R 105 -G 112 -B 103
  $timeHelp.Location = New-Object System.Drawing.Point(24, 50)
  $timeHelp.Size = New-Object System.Drawing.Size(390, 24)
  $planCard.Controls.Add($timeHelp)

  $yarnLabel = New-Object System.Windows.Forms.Label
  # yarn-progress-marker
  $yarnLabel.Text = "毛线球进度  O---- 今日状态已汇总"
  $yarnLabel.Font = New-UiFont -Size 9
  $yarnLabel.ForeColor = New-UiColor -R 176 -G 103 -B 75
  $yarnLabel.Location = New-Object System.Drawing.Point(24, 76)
  $yarnLabel.Size = New-Object System.Drawing.Size(320, 22)
  $planCard.Controls.Add($yarnLabel)

  $timePicker = New-Object System.Windows.Forms.DateTimePicker
  $timePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
  $timePicker.CustomFormat = "HH:mm"
  $timePicker.ShowUpDown = $true
  $timePicker.Font = New-UiFont -Size 12
  $timePicker.Location = New-Object System.Drawing.Point(600, 24)
  $timePicker.Size = New-Object System.Drawing.Size(132, 30)
  $parsed = [datetime]::ParseExact($settings.dailyRunTime, "HH:mm", $null)
  $timePicker.Value = Get-Date -Hour $parsed.Hour -Minute $parsed.Minute -Second 0
  $planCard.Controls.Add($timePicker)

  $startupCheck = New-Object System.Windows.Forms.CheckBox
  $startupCheck.Text = "开机自启动"
  $startupCheck.Checked = [bool]$settings.startWithWindows
  $startupCheck.Font = New-UiFont -Size 10
  $startupCheck.Location = New-Object System.Drawing.Point(440, 72)
  $startupCheck.Size = New-Object System.Drawing.Size(160, 28)
  $planCard.Controls.Add($startupCheck)

  $keepReportsCheck = New-Object System.Windows.Forms.CheckBox
  $keepReportsCheck.Text = "调试时保留本地报告"
  $keepReportsCheck.Checked = [bool]$settings.keepReports
  $keepReportsCheck.Font = New-UiFont -Size 10
  $keepReportsCheck.Location = New-Object System.Drawing.Point(440, 96)
  $keepReportsCheck.Size = New-Object System.Drawing.Size(220, 28)
  $planCard.Controls.Add($keepReportsCheck)

  $runButton = New-Object System.Windows.Forms.Button
  $runButton.Text = "立即签到"
  $runButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $runButton.FlatAppearance.BorderSize = 0
  $runButton.BackColor = New-UiColor -R 205 -G 102 -B 72
  $runButton.ForeColor = [System.Drawing.Color]::White
  $runButton.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
  $runButton.Location = New-Object System.Drawing.Point(650, 74)
  $runButton.Size = New-Object System.Drawing.Size(106, 34)
  $runButton.Add_Click({
    if (Confirm-Action -Title "启动签到" -Message "确定现在启动一次签到？结果会通过邮件发送，临时报告会按设置清理。") {
      Start-Checkin -Reason "manual"
    }
  })
  $planCard.Controls.Add($runButton)

  $content.Controls.Add((New-SectionLabel -Text "站点状态" -X 58 -Y 398))

  $grid = New-Object System.Windows.Forms.DataGridView
  $grid.Location = New-Object System.Drawing.Point(56, 426)
  $grid.Size = New-Object System.Drawing.Size(790, 162)
  $grid.AllowUserToAddRows = $false
  $grid.AllowUserToDeleteRows = $false
  $grid.RowHeadersVisible = $false
  $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
  $grid.BackgroundColor = New-UiColor -R 255 -G 252 -B 247
  $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $grid.GridColor = New-UiColor -R 224 -G 228 -B 220
  $grid.ColumnHeadersDefaultCellStyle.BackColor = New-UiColor -R 237 -G 240 -B 235
  $grid.ColumnHeadersDefaultCellStyle.ForeColor = New-UiColor -R 55 -G 62 -B 56
  $grid.ColumnHeadersDefaultCellStyle.Font = New-UiFont -Size 9.2 -Style ([System.Drawing.FontStyle]::Bold)
  $grid.DefaultCellStyle.BackColor = New-UiColor -R 255 -G 252 -B 247
  $grid.DefaultCellStyle.ForeColor = New-UiColor -R 45 -G 51 -B 47
  $grid.DefaultCellStyle.SelectionBackColor = New-UiColor -R 226 -G 235 -B 226
  $grid.DefaultCellStyle.SelectionForeColor = New-UiColor -R 36 -G 42 -B 38

  $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $nameColumn.Name = "Name"
  $nameColumn.HeaderText = "站点"
  $nameColumn.ReadOnly = $true
  $grid.Columns.Add($nameColumn) | Out-Null

  $statusColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $statusColumn.Name = "Status"
  $statusColumn.HeaderText = "今日状态"
  $statusColumn.ReadOnly = $true
  $grid.Columns.Add($statusColumn) | Out-Null

  $enabledColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
  $enabledColumn.Name = "Enabled"
  $enabledColumn.HeaderText = "启用"
  $grid.Columns.Add($enabledColumn) | Out-Null

  $manualColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
  $manualColumn.Name = "ManualReminderOnly"
  $manualColumn.HeaderText = "手动提醒"
  $grid.Columns.Add($manualColumn) | Out-Null

  $urlColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $urlColumn.Name = "Url"
  $urlColumn.HeaderText = "地址"
  $urlColumn.ReadOnly = $true
  $grid.Columns.Add($urlColumn) | Out-Null

  foreach ($site in $config.sites) {
    $siteSetting = Get-SettingSite -Settings $settings -Name $site.name
    $enabled = if ($siteSetting) { [bool]$siteSetting.enabled } else { $true }
    $manual = if ($siteSetting) { [bool]$siteSetting.manualReminderOnly } else { (($site.PSObject.Properties.Name -contains "manualReminderOnly") -and [bool]$site.manualReminderOnly) }
    $statusText = if ($manual) { "需要处理" } else { "全部正常" }
    $rowIndex = $grid.Rows.Add($site.name, $statusText, $enabled, $manual, $site.url)
    if ($manual) {
      $grid.Rows[$rowIndex].Cells["Status"].Style.ForeColor = New-UiColor -R 185 -G 88 -B 62
    }
    else {
      $grid.Rows[$rowIndex].Cells["Status"].Style.ForeColor = New-UiColor -R 83 -G 124 -B 91
    }
  }
  $content.Controls.Add($grid)

  $okMarker = New-PawStatusLabel -Text "自动签到站点：全部正常"
  $okMarker.Location = New-Object System.Drawing.Point(56, 598)
  $content.Controls.Add($okMarker)

  $attentionMarker = New-PawStatusLabel -Text "手动提醒站点：需要处理" -Attention $true
  $attentionMarker.Location = New-Object System.Drawing.Point(248, 598)
  $content.Controls.Add($attentionMarker)

  $smtpLabel = New-Object System.Windows.Forms.Label
  $smtpLabel.Text = "邮件提醒"
  $smtpLabel.Font = New-UiFont -Size 10.5 -Style ([System.Drawing.FontStyle]::Bold)
  $smtpLabel.ForeColor = New-UiColor -R 88 -G 94 -B 86
  $smtpLabel.Location = New-Object System.Drawing.Point(58, 632)
  $smtpLabel.Size = New-Object System.Drawing.Size(200, 24)
  $content.Controls.Add($smtpLabel)

  $smtpBox = New-Object System.Windows.Forms.TextBox
  $smtpBox.Multiline = $true
  $smtpBox.ReadOnly = $true
  $smtpBox.ScrollBars = "Vertical"
  $smtpBox.Text = Get-SmtpStatusText
  $smtpBox.Font = New-UiFont -Size 9
  $smtpBox.BackColor = New-UiColor -R 255 -G 252 -B 247
  $smtpBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $smtpBox.Location = New-Object System.Drawing.Point(56, 660)
  $smtpBox.Size = New-Object System.Drawing.Size(520, 70)
  $content.Controls.Add($smtpBox)

  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = "保存"
  $saveButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $saveButton.FlatAppearance.BorderSize = 0
  $saveButton.BackColor = New-UiColor -R 205 -G 102 -B 72
  $saveButton.ForeColor = [System.Drawing.Color]::White
  $saveButton.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
  $saveButton.Location = New-Object System.Drawing.Point(620, 664)
  $saveButton.Size = New-Object System.Drawing.Size(90, 34)
  $content.Controls.Add($saveButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = "关闭"
  $cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $cancelButton.FlatAppearance.BorderColor = New-UiColor -R 210 -G 214 -B 206
  $cancelButton.BackColor = New-UiColor -R 255 -G 255 -B 252
  $cancelButton.Font = New-UiFont -Size 10
  $cancelButton.Location = New-Object System.Drawing.Point(722, 664)
  $cancelButton.Size = New-Object System.Drawing.Size(90, 34)
  $cancelButton.Add_Click({ $form.Close() })
  $content.Controls.Add($cancelButton)

  $form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:SettingsWindowProgrammaticClose) {
      return
    }

    $choice = [System.Windows.Forms.MessageBox]::Show(
      "关闭设置窗口？`n`n是：关闭窗口并保留托盘运行`n否：退出整个托盘工具`n取消：继续留在设置窗口",
      "关闭确认",
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
      $eventArgs.Cancel = $true
      return
    }
    if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
      Close-TrayApp
      return
    }
  })

  $saveButton.Add_Click({
    $newSettings = Get-DefaultSettings
    $newSettings.dailyRunTime = $timePicker.Value.ToString("HH:mm")
    $newSettings.startWithWindows = [bool]$startupCheck.Checked
    $newSettings.keepReports = [bool]$keepReportsCheck.Checked
    $newSettings.lastScheduledRunDate = $script:Settings.lastScheduledRunDate

    foreach ($row in $grid.Rows) {
      $siteName = [string]$row.Cells["Name"].Value
      if ($newSettings.sites.PSObject.Properties.Name -contains $siteName) {
        $newSettings.sites.$siteName.enabled = [bool]$row.Cells["Enabled"].Value
        $newSettings.sites.$siteName.manualReminderOnly = [bool]$row.Cells["ManualReminderOnly"].Value
      }
    }

    Set-StartupShortcut -Enabled ([bool]$newSettings.startWithWindows)
    Save-Settings -Settings $newSettings
    $script:Settings = $newSettings
    Update-TrayState -Status "Settings saved"
    Show-Balloon -Title "Settings saved" -Text "Tray check-in settings were updated."
    $script:SettingsWindowProgrammaticClose = $true
    $form.Close()
    $script:SettingsWindowProgrammaticClose = $false
  })

  $form.Add_FormClosed({
    $script:SettingsForm = $null
    $script:SettingsWindowProgrammaticClose = $false
  })

  $form.Show()
}

Load-Settings | Out-Null

if ($ValidateOnly) {
  Write-Output "checkin-tray validation ok"
  Write-Output "settings=$((Resolve-Path -Path $SettingsPath).Path)"
  exit 0
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Visible = $true
$notify.Text = "bb-browser check-in - Idle"
$script:NotifyIcon = $notify

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:RunNowMenuItem = $menu.Items.Add("Run check-in now")
$script:RunNowMenuItem.Add_Click({
  if (Confirm-Action -Title "启动签到" -Message "确定现在启动一次签到？结果会通过邮件发送，临时报告会按设置清理。") {
    Start-Checkin -Reason "manual"
  }
})
$menu.Items.Add("Settings").Add_Click({ Show-SettingsWindow })
$menu.Items.Add("Open Linux.do login").Add_Click({ Open-LinuxDoLogin })
$menu.Items.Add("Send test email").Add_Click({ Send-TestEmail })
$menu.Items.Add("Clean temporary reports").Add_Click({ Cleanup-LocalReports })
$menu.Items.Add("-") | Out-Null
$menu.Items.Add("Exit").Add_Click({
  if ($script:CheckinRunning) {
    Show-Balloon -Title "Check-in running" -Text "Wait for the current run before exiting."
    return
  }
  if (Confirm-Action -Title "退出确认" -Message "确定退出托盘签到工具？退出后不会继续定时签到。") {
    Close-TrayApp
  }
})
$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ Show-SettingsWindow })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.Add_Tick({
  Complete-CheckinJob
  Test-DailySchedule
})
$timer.Start()

Update-TrayState -Status "Waiting"
Show-Balloon -Title "bb-browser check-in" -Text "Tray tool is running. Double-click the icon for settings."
Show-SettingsWindow
[System.Windows.Forms.Application]::Run()

