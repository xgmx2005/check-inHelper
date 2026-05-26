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

function New-CardPanel {
  param(
    [int]$X,
    [int]$Y,
    [int]$Width,
    [int]$Height
  )

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($X, $Y)
  $panel.Size = New-Object System.Drawing.Size($Width, $Height)
  $panel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)
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

function New-SidebarItem {
  param(
    [string]$Text,
    [int]$Y,
    [bool]$Active = $false
  )

  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point(14, $Y)
  $button.Size = New-Object System.Drawing.Size(236, 42)
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 0
  $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $button.Font = New-UiFont -Size 10
  $button.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  if ($Active) {
    $button.BackColor = [System.Drawing.Color]::White
    $button.ForeColor = [System.Drawing.Color]::FromArgb(26, 32, 44)
  }
  else {
    $button.BackColor = [System.Drawing.Color]::FromArgb(235, 236, 241)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(91, 98, 112)
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
  $form.Text = "bb-browser 签到设置"
  $form.StartPosition = "CenterScreen"
  $form.Size = New-Object System.Drawing.Size(1120, 760)
  $form.MinimumSize = New-Object System.Drawing.Size(1040, 700)
  $form.BackColor = [System.Drawing.Color]::White
  $form.Font = New-UiFont -Size 9.5
  $script:SettingsForm = $form

  $sidebarWidth = 286 # layout-sidebar-width
  $contentOriginX = $sidebarWidth # layout-content-origin

  $sidebar = New-Object System.Windows.Forms.Panel
  $sidebar.Location = New-Object System.Drawing.Point(0, 0)
  $sidebar.Size = New-Object System.Drawing.Size($sidebarWidth, $form.ClientSize.Height)
  $sidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $sidebar.BackColor = [System.Drawing.Color]::FromArgb(235, 236, 241)
  $form.Controls.Add($sidebar)

  $brand = New-Object System.Windows.Forms.Label
  $brand.Text = "公益站签到"
  $brand.Font = New-UiFont -Size 13 -Style ([System.Drawing.FontStyle]::Bold)
  $brand.ForeColor = [System.Drawing.Color]::FromArgb(37, 42, 54)
  $brand.Location = New-Object System.Drawing.Point(20, 20)
  $brand.Size = New-Object System.Drawing.Size(220, 28)
  $sidebar.Controls.Add($brand)

  $subBrand = New-Object System.Windows.Forms.Label
  $subBrand.Text = "bb-browser tray controller"
  $subBrand.Font = New-UiFont -Size 8.5
  $subBrand.ForeColor = [System.Drawing.Color]::FromArgb(119, 126, 141)
  $subBrand.Location = New-Object System.Drawing.Point(22, 50)
  $subBrand.Size = New-Object System.Drawing.Size(220, 22)
  $sidebar.Controls.Add($subBrand)

  $sidebar.Controls.Add((New-SidebarItem -Text "⚙  通用" -Y 96 -Active $true))
  $sidebar.Controls.Add((New-SidebarItem -Text "☑  站点管理" -Y 146))
  $sidebar.Controls.Add((New-SidebarItem -Text "✉  邮件状态" -Y 196))
  $sidebar.Controls.Add((New-SidebarItem -Text "🧹  清理策略" -Y 246))

  $doctor = New-Object System.Windows.Forms.Panel
  $doctor.Location = New-Object System.Drawing.Point(14, 632)
  $doctor.Size = New-Object System.Drawing.Size(252, 48)
  $doctor.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $doctor.BackColor = [System.Drawing.Color]::FromArgb(226, 228, 234)
  $doctor.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $sidebar.Controls.Add($doctor)

  $doctorText = New-Object System.Windows.Forms.Label
  $doctorText.Text = "● Doctor    $($script:LastStatus)"
  $doctorText.Font = New-UiFont -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
  $doctorText.ForeColor = [System.Drawing.Color]::FromArgb(84, 91, 105)
  $doctorText.Location = New-Object System.Drawing.Point(16, 14)
  $doctorText.Size = New-Object System.Drawing.Size(200, 22)
  $doctor.Controls.Add($doctorText)

  $content = New-Object System.Windows.Forms.Panel
  $content.Location = New-Object System.Drawing.Point($contentOriginX, 0)
  $content.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - $contentOriginX), $form.ClientSize.Height)
  $content.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $content.BackColor = [System.Drawing.Color]::White
  $form.Controls.Add($content)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = "设置"
  $title.Font = New-UiFont -Size 22 -Style ([System.Drawing.FontStyle]::Bold)
  $title.Location = New-Object System.Drawing.Point(52, 42)
  $title.Size = New-Object System.Drawing.Size(240, 44)
  $content.Controls.Add($title)

  $status = New-Object System.Windows.Forms.Label
  $status.Text = "配置托盘签到工具在桌面上的行为。当前状态：$($script:LastStatus)"
  $status.Font = New-UiFont -Size 10
  $status.ForeColor = [System.Drawing.Color]::FromArgb(87, 94, 110)
  $status.Location = New-Object System.Drawing.Point(56, 86)
  $status.Size = New-Object System.Drawing.Size(740, 28)
  $content.Controls.Add($status)

  $content.Controls.Add((New-SectionLabel -Text "外观与计划" -X 58 -Y 138))

  $planCard = New-CardPanel -X 56 -Y 168 -Width 740 -Height 150
  $content.Controls.Add($planCard)

  $timeLabel = New-Object System.Windows.Forms.Label
  $timeLabel.Text = "每日自动签到"
  $timeLabel.Font = New-UiFont -Size 11 -Style ([System.Drawing.FontStyle]::Bold)
  $timeLabel.Location = New-Object System.Drawing.Point(24, 24)
  $timeLabel.Size = New-Object System.Drawing.Size(180, 24)
  $planCard.Controls.Add($timeLabel)

  $timeHelp = New-Object System.Windows.Forms.Label
  $timeHelp.Text = "托盘工具启动后，到这个时间会自动运行一次。"
  $timeHelp.ForeColor = [System.Drawing.Color]::FromArgb(105, 112, 126)
  $timeHelp.Location = New-Object System.Drawing.Point(24, 50)
  $timeHelp.Size = New-Object System.Drawing.Size(360, 24)
  $planCard.Controls.Add($timeHelp)

  $timePicker = New-Object System.Windows.Forms.DateTimePicker
  $timePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
  $timePicker.CustomFormat = "HH:mm"
  $timePicker.ShowUpDown = $true
  $timePicker.Font = New-UiFont -Size 12
  $timePicker.Location = New-Object System.Drawing.Point(560, 26)
  $timePicker.Size = New-Object System.Drawing.Size(132, 30)
  $parsed = [datetime]::ParseExact($settings.dailyRunTime, "HH:mm", $null)
  $timePicker.Value = Get-Date -Hour $parsed.Hour -Minute $parsed.Minute -Second 0
  $planCard.Controls.Add($timePicker)

  $startupCheck = New-Object System.Windows.Forms.CheckBox
  $startupCheck.Text = "开机自启动"
  $startupCheck.Checked = [bool]$settings.startWithWindows
  $startupCheck.Font = New-UiFont -Size 10
  $startupCheck.Location = New-Object System.Drawing.Point(28, 102)
  $startupCheck.Size = New-Object System.Drawing.Size(160, 28)
  $planCard.Controls.Add($startupCheck)

  $keepReportsCheck = New-Object System.Windows.Forms.CheckBox
  $keepReportsCheck.Text = "调试时保留本地报告"
  $keepReportsCheck.Checked = [bool]$settings.keepReports
  $keepReportsCheck.Font = New-UiFont -Size 10
  $keepReportsCheck.Location = New-Object System.Drawing.Point(226, 102)
  $keepReportsCheck.Size = New-Object System.Drawing.Size(220, 28)
  $planCard.Controls.Add($keepReportsCheck)

  $runButton = New-Object System.Windows.Forms.Button
  $runButton.Text = "立即签到"
  $runButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $runButton.FlatAppearance.BorderSize = 0
  $runButton.BackColor = [System.Drawing.Color]::FromArgb(218, 112, 78)
  $runButton.ForeColor = [System.Drawing.Color]::White
  $runButton.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
  $runButton.Location = New-Object System.Drawing.Point(590, 96)
  $runButton.Size = New-Object System.Drawing.Size(106, 34)
  $runButton.Add_Click({
    if (Confirm-Action -Title "启动签到" -Message "确定现在启动一次签到？结果会通过邮件发送，临时报告会按设置清理。") {
      Start-Checkin -Reason "manual"
    }
  })
  $planCard.Controls.Add($runButton)

  $content.Controls.Add((New-SectionLabel -Text "站点管理" -X 58 -Y 338))

  $grid = New-Object System.Windows.Forms.DataGridView
  $grid.Location = New-Object System.Drawing.Point(56, 366)
  $grid.Size = New-Object System.Drawing.Size(740, 178)
  $grid.AllowUserToAddRows = $false
  $grid.AllowUserToDeleteRows = $false
  $grid.RowHeadersVisible = $false
  $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
  $grid.BackgroundColor = [System.Drawing.Color]::FromArgb(248, 249, 252)
  $grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $grid.GridColor = [System.Drawing.Color]::FromArgb(224, 226, 232)

  $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $nameColumn.Name = "Name"
  $nameColumn.HeaderText = "Site"
  $nameColumn.ReadOnly = $true
  $grid.Columns.Add($nameColumn) | Out-Null

  $enabledColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
  $enabledColumn.Name = "Enabled"
  $enabledColumn.HeaderText = "Enabled"
  $grid.Columns.Add($enabledColumn) | Out-Null

  $manualColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
  $manualColumn.Name = "ManualReminderOnly"
  $manualColumn.HeaderText = "Manual reminder only"
  $grid.Columns.Add($manualColumn) | Out-Null

  $urlColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $urlColumn.Name = "Url"
  $urlColumn.HeaderText = "URL"
  $urlColumn.ReadOnly = $true
  $grid.Columns.Add($urlColumn) | Out-Null

  foreach ($site in $config.sites) {
    $siteSetting = Get-SettingSite -Settings $settings -Name $site.name
    $enabled = if ($siteSetting) { [bool]$siteSetting.enabled } else { $true }
    $manual = if ($siteSetting) { [bool]$siteSetting.manualReminderOnly } else { (($site.PSObject.Properties.Name -contains "manualReminderOnly") -and [bool]$site.manualReminderOnly) }
    $grid.Rows.Add($site.name, $enabled, $manual, $site.url) | Out-Null
  }
  $content.Controls.Add($grid)

  $smtpLabel = New-Object System.Windows.Forms.Label
  $smtpLabel.Text = "邮件环境"
  $smtpLabel.Font = New-UiFont -Size 10.5 -Style ([System.Drawing.FontStyle]::Bold)
  $smtpLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 94, 107)
  $smtpLabel.Location = New-Object System.Drawing.Point(58, 562)
  $smtpLabel.Size = New-Object System.Drawing.Size(200, 24)
  $content.Controls.Add($smtpLabel)

  $smtpBox = New-Object System.Windows.Forms.TextBox
  $smtpBox.Multiline = $true
  $smtpBox.ReadOnly = $true
  $smtpBox.ScrollBars = "Vertical"
  $smtpBox.Text = Get-SmtpStatusText
  $smtpBox.Font = New-UiFont -Size 9
  $smtpBox.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)
  $smtpBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $smtpBox.Location = New-Object System.Drawing.Point(56, 590)
  $smtpBox.Size = New-Object System.Drawing.Size(520, 72)
  $content.Controls.Add($smtpBox)

  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = "保存"
  $saveButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $saveButton.FlatAppearance.BorderSize = 0
  $saveButton.BackColor = [System.Drawing.Color]::FromArgb(218, 112, 78)
  $saveButton.ForeColor = [System.Drawing.Color]::White
  $saveButton.Font = New-UiFont -Size 10 -Style ([System.Drawing.FontStyle]::Bold)
  $saveButton.Location = New-Object System.Drawing.Point(604, 596)
  $saveButton.Size = New-Object System.Drawing.Size(90, 34)
  $content.Controls.Add($saveButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = "关闭"
  $cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $cancelButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(210, 214, 222)
  $cancelButton.BackColor = [System.Drawing.Color]::White
  $cancelButton.Font = New-UiFont -Size 10
  $cancelButton.Location = New-Object System.Drawing.Point(706, 596)
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

