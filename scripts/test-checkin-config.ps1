param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\checkin-sites.json"),
  [string]$ScriptPath = (Join-Path $PSScriptRoot "daily-checkin.ps1"),
  [string]$AgentScriptPath = (Join-Path $PSScriptRoot "run-agent-checkin.ps1"),
  [string]$TrayScriptPath = (Join-Path $PSScriptRoot "checkin-tray.ps1"),
  [string]$TraySettingsPath = (Join-Path $PSScriptRoot "..\config\tray-settings.json"),
  [string]$ShortcutScriptPath = (Join-Path $PSScriptRoot "create-checkin-tray-shortcut.ps1"),
  [string]$LauncherPath = (Join-Path $PSScriptRoot "..\launch-checkin-tray.cmd")
)

$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$scriptText = Get-Content -Path $ScriptPath -Raw -Encoding UTF8
$immediateCheckin = -join ([char[]](0x7acb, 0x5373, 0x7b7e, 0x5230))
$quota = -join ([char[]](0x989d, 0x5ea6))
$smallCatAssistant = -join ([char[]](0x5c0f, 0x732b, 0x52a9, 0x624b))
$healthyState = -join ([char[]](0x5168, 0x90e8, 0x6b63, 0x5e38))
$attentionState = -join ([char[]](0x9700, 0x8981, 0x5904, 0x7406))

Assert-True -Condition ($config.defaults.buttonKeywords -contains $immediateCheckin) `
  -Message "buttonKeywords must include the real New API check-in button text"

Assert-True -Condition (-not ($config.defaults.successKeywords -contains $quota)) `
  -Message "successKeywords must not include generic quota text"

Assert-True -Condition ($config.defaults.personalSettingsPaths -contains "/console/personal") `
  -Message "personalSettingsPaths must include /console/personal"

Assert-True -Condition ($scriptText -match "Invoke-NavigateToPersonalSettings") `
  -Message "daily-checkin.ps1 must explicitly navigate to personal settings before checking in"

Assert-True -Condition ($scriptText -match "Invoke-StartLinuxDoOAuth") `
  -Message "daily-checkin.ps1 must fall back to same-tab Linux.do OAuth navigation"

$reminderOnlySites = @($config.sites | Where-Object { $_.manualReminderOnly })
$reminderOnlyNames = @($reminderOnlySites | ForEach-Object { $_.name })
Assert-True -Condition ($reminderOnlyNames -contains "muyuan") `
  -Message "muyuan must be configured as manual reminder only"

Assert-True -Condition ($reminderOnlyNames -contains "lpgpt") `
  -Message "lpgpt must be configured as manual reminder only"

Assert-True -Condition ($scriptText -match "manual_reminder") `
  -Message "daily-checkin.ps1 must report manual reminder-only sites without opening them"

Assert-True -Condition (Test-Path -Path $AgentScriptPath) `
  -Message "run-agent-checkin.ps1 must provide an agent-agnostic entrypoint"

$agentScriptText = Get-Content -Path $AgentScriptPath -Raw -Encoding UTF8
Assert-True -Condition ($agentScriptText -match "daily-checkin\.ps1") `
  -Message "agent entrypoint must call daily-checkin.ps1"

Assert-True -Condition ($agentScriptText -match '-ConfigPath\s+\$ConfigPath') `
  -Message "agent entrypoint must pass ConfigPath through to daily-checkin.ps1"

Assert-True -Condition ($agentScriptText -match "send_reminder_email\.py") `
  -Message "agent entrypoint must call the real HTML SMTP reminder sender"

Assert-True -Condition ($agentScriptText -match "result\.json") `
  -Message "agent entrypoint must resolve the newest result.json report"

Assert-True -Condition ($agentScriptText -match "MinLastWriteTime") `
  -Message "agent entrypoint must not reuse stale result.json files from earlier runs"

Assert-True -Condition ($agentScriptText -match "Write-InfrastructureFailureReport") `
  -Message "agent entrypoint must write a current failure report when check-in fails before result.json is created"

Assert-True -Condition ($agentScriptText -match "Cleanup-ReportDirectories") `
  -Message "agent entrypoint must clean report directories after the email/summary path finishes"

Assert-True -Condition ($agentScriptText -match 'Get-ChildItem -Path \$resolvedRoot -File') `
  -Message "agent entrypoint cleanup must remove root-level temporary report files too"

Assert-True -Condition ($agentScriptText -match "KeepReports") `
  -Message "agent entrypoint must provide an explicit KeepReports escape hatch for debugging"

Assert-True -Condition ($agentScriptText -match "CHECKIN_SMTP_") `
  -Message "agent entrypoint must document/use SMTP environment variables instead of agent-specific connectors"

Assert-True -Condition ($agentScriptText -match "PYTHONIOENCODING") `
  -Message "agent entrypoint must force UTF-8 Python I/O when invoking the email sender"

Assert-True -Condition (Test-Path -Path $TrayScriptPath) `
  -Message "checkin-tray.ps1 must provide the Windows tray UI entrypoint"

$trayScriptText = Get-Content -Path $TrayScriptPath -Raw -Encoding UTF8
Assert-True -Condition ($trayScriptText -match "System\.Windows\.Forms") `
  -Message "tray entrypoint must use WinForms"

Assert-True -Condition ($trayScriptText -match "NotifyIcon") `
  -Message "tray entrypoint must create a NotifyIcon"

Assert-True -Condition ($trayScriptText -match "Show-SettingsWindow") `
  -Message "tray entrypoint must provide a settings window"

Assert-True -Condition ($trayScriptText -match "Confirm-Action") `
  -Message "tray entrypoint must ask before starting or exiting key actions"

Assert-True -Condition ($trayScriptText -match "FormClosing") `
  -Message "settings window must ask what to do when closed"

Assert-True -Condition ($trayScriptText -match "YesNoCancel") `
  -Message "settings close prompt must support minimize, exit, and cancel"

Assert-True -Condition ($trayScriptText -match "New-CardPanel") `
  -Message "settings window must use card-style panels"

Assert-True -Condition ($trayScriptText -match "New-SidebarItem") `
  -Message "settings window must include a left navigation sidebar"

Assert-True -Condition ($trayScriptText -match "New-CatMascotLabel") `
  -Message "settings window must include a cat mascot helper"

Assert-True -Condition ($trayScriptText -match "New-StatusSummaryCard") `
  -Message "settings window must include compact status summary cards"

Assert-True -Condition ($trayScriptText -match "yarn-progress-marker") `
  -Message "settings window must include the yarn-ball progress accent from the design"

Assert-True -Condition ($trayScriptText -match "paw-status-marker") `
  -Message "settings window must include paw-style status markers"

Assert-True -Condition ($trayScriptText -match "Check-in Helper") `
  -Message "settings window must use the new Check-in Helper product title"

Assert-True -Condition ($trayScriptText -match [regex]::Escape($smallCatAssistant)) `
  -Message "settings window must include the small cat assistant copy"

Assert-True -Condition ($trayScriptText -match [regex]::Escape($healthyState) -and $trayScriptText -match [regex]::Escape($attentionState)) `
  -Message "settings window must surface healthy and attention-needed states"

Assert-True -Condition ($trayScriptText -match "layout-sidebar-width") `
  -Message "settings window must define a stable sidebar width for side-by-side layout"

Assert-True -Condition ($trayScriptText -match "layout-content-origin") `
  -Message "settings content must start to the right of the sidebar"

Assert-True -Condition (-not ($trayScriptText -match '\$content\.Dock\s*=\s*\[System\.Windows\.Forms\.DockStyle\]::Fill')) `
  -Message "settings content must not Dock Fill under the sidebar"

Assert-True -Condition ($trayScriptText -match 'Show-SettingsWindow\r?\n\[System\.Windows\.Forms\.Application\]::Run') `
  -Message "tray app must show a real window on launch, not only a tray icon"

Assert-True -Condition ($trayScriptText -match "run-agent-checkin\.ps1") `
  -Message "tray entrypoint must call the agent-agnostic check-in entrypoint"

Assert-True -Condition ($trayScriptText -match "PYTHONIOENCODING") `
  -Message "tray entrypoint must force UTF-8 Python I/O when invoking the email sender"

Assert-True -Condition ($trayScriptText -match "checkin-running-state") `
  -Message "tray entrypoint must prevent duplicate concurrent check-in runs"

Assert-True -Condition ($trayScriptText -match "SpecialFolder\]::Startup") `
  -Message "tray startup toggle must write only to the current user's Startup folder"

Assert-True -Condition ($trayScriptText -match 'Get-ChildItem -Path \$resolvedRoot -File') `
  -Message "tray cleanup must remove root-level temporary report files too"

Assert-True -Condition (-not ($trayScriptText -match "HKLM|AllUsersStartup|CHECKIN_SMTP_PASS\s*=")) `
  -Message "tray entrypoint must not use machine-wide startup or persist SMTP passwords"

Assert-True -Condition (Test-Path -Path $TraySettingsPath) `
  -Message "tray-settings.json must provide default non-secret settings"

$traySettingsText = Get-Content -Path $TraySettingsPath -Raw -Encoding UTF8
$traySettings = $traySettingsText | ConvertFrom-Json
Assert-True -Condition ($traySettings.dailyRunTime -match "^\d{2}:\d{2}$") `
  -Message "tray settings must include a HH:mm dailyRunTime default"

Assert-True -Condition ($traySettings.PSObject.Properties.Name -contains "startWithWindows") `
  -Message "tray settings must include startWithWindows"

Assert-True -Condition ($traySettings.PSObject.Properties.Name -contains "keepReports") `
  -Message "tray settings must include keepReports"

Assert-True -Condition ($traySettings.PSObject.Properties.Name -contains "sites") `
  -Message "tray settings must include per-site settings"

Assert-True -Condition (-not ($traySettingsText -match "CHECKIN_SMTP_PASS|smtpPassword|password")) `
  -Message "tray settings must not store SMTP passwords"

Assert-True -Condition (Test-Path -Path $LauncherPath) `
  -Message "repository root must provide a double-click tray launcher cmd"

$launcherText = Get-Content -Path $LauncherPath -Raw -Encoding UTF8
Assert-True -Condition ($launcherText -match "checkin-tray\.ps1") `
  -Message "tray launcher cmd must start checkin-tray.ps1"

Assert-True -Condition ($launcherText -match "WindowStyle Hidden") `
  -Message "tray launcher cmd must hide the terminal window"

Assert-True -Condition (Test-Path -Path $ShortcutScriptPath) `
  -Message "create-checkin-tray-shortcut.ps1 must install a desktop shortcut"

$shortcutScriptText = Get-Content -Path $ShortcutScriptPath -Raw -Encoding UTF8
Assert-True -Condition ($shortcutScriptText -match "SpecialFolder\]::DesktopDirectory") `
  -Message "shortcut installer must target the current user's desktop"

Assert-True -Condition ($shortcutScriptText -match "WScript\.Shell") `
  -Message "shortcut installer must use a Windows shell shortcut"

Assert-True -Condition ($shortcutScriptText -match "WindowStyle Hidden") `
  -Message "desktop shortcut must launch without leaving a terminal window"

Assert-True -Condition ($shortcutScriptText -match "checkin-tray\.ps1") `
  -Message "desktop shortcut must point at checkin-tray.ps1"

Assert-True -Condition (-not ($shortcutScriptText -match "HKLM|AllUsersDesktop|CHECKIN_SMTP_PASS\s*=")) `
  -Message "shortcut installer must not use machine-wide locations or persist SMTP passwords"

Write-Host "check-in config tests ok"
