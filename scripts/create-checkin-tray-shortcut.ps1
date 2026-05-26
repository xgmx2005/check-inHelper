param(
  [string]$ShortcutName = "bb-browser check-in tray",
  [string]$TrayScriptPath = (Join-Path $PSScriptRoot "checkin-tray.ps1"),
  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Get-DesktopShortcutPath {
  $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  if ([string]::IsNullOrWhiteSpace($desktop)) {
    $desktop = Join-Path $env:USERPROFILE "Desktop"
  }
  Join-Path $desktop "$ShortcutName.lnk"
}

function New-CheckinTrayShortcut {
  $resolvedTrayScript = (Resolve-Path -Path $TrayScriptPath).Path
  $shortcutPath = Get-DesktopShortcutPath
  $workingDirectory = (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = (Get-Command powershell.exe -ErrorAction Stop).Source
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$resolvedTrayScript`""
  $shortcut.WorkingDirectory = $workingDirectory
  $shortcut.Description = "Open the bb-browser check-in tray tool"
  $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
  $shortcut.Save()

  $shortcutPath
}

if ($ValidateOnly) {
  Write-Output "shortcut installer validation ok"
  Write-Output "shortcut=$((Get-DesktopShortcutPath))"
  exit 0
}

$created = New-CheckinTrayShortcut
Write-Output "Created shortcut: $created"
