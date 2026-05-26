param(
  [string]$ReportsDir = (Join-Path $PSScriptRoot "..\reports"),
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\checkin-sites.json"),
  [int]$BbTimeoutSeconds = 45,
  [string]$Python = "python",
  [switch]$SkipCheckin,
  [switch]$NoEmail,
  [switch]$DryRunEmail,
  [switch]$KeepReports
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$manualReminderSiteNames = @("muyuan", "lpgpt")
$manualReminderStatuses = @("manual_reminder", "failed", "unknown", "network_error")

function Get-NewestResultJson {
  param(
    [string]$Root,
    [datetime]$MinLastWriteTime = [datetime]::MinValue
  )

  if (-not (Test-Path -Path $Root)) {
    throw "Reports directory does not exist: $Root"
  }

  $latest = Get-ChildItem -Path $Root -Directory |
    Sort-Object -Property LastWriteTime -Descending |
    ForEach-Object {
      $candidate = Join-Path $_.FullName "result.json"
      if (Test-Path -Path $candidate) {
        $item = Get-Item -Path $candidate
        if ($item.LastWriteTime -ge $MinLastWriteTime) {
          $item
        }
      }
    } |
    Select-Object -First 1

  if (-not $latest) {
    throw "No current result.json found under: $Root"
  }

  $latest.FullName
}

function ConvertTo-ReportCell {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  (($Value -replace "\r?\n", " ") -replace "\|", "\|").Trim()
}

function New-ReportItem {
  param(
    [string]$Name,
    [string]$Url,
    [string]$Status,
    [string]$Reason
  )

  [pscustomobject]@{
    name = $Name
    url = $Url
    status = $Status
    reason = $Reason
    finalUrl = $Url
    title = ""
    screenshot = ""
    timestamp = (Get-Date).ToString("s")
  }
}

function Write-ResultFiles {
  param(
    [string]$RunDir,
    [object[]]$Results,
    [bool]$DryRun
  )

  $resultJson = Join-Path $RunDir "result.json"
  $resultMarkdown = Join-Path $RunDir "result.md"

  $Results | ConvertTo-Json -Depth 8 | Set-Content -Path $resultJson -Encoding UTF8

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Daily check-in report")
  $lines.Add("")
  $lines.Add("- Time: $((Get-Date).ToString("s"))")
  $lines.Add("- Dry run: $DryRun")
  $lines.Add("")
  $lines.Add("| Site | Status | Reason | Final URL | Screenshot |")
  $lines.Add("| --- | --- | --- | --- | --- |")
  foreach ($result in $Results) {
    $lines.Add("| $(ConvertTo-ReportCell $result.name) | $(ConvertTo-ReportCell $result.status) | $(ConvertTo-ReportCell $result.reason) | $(ConvertTo-ReportCell $result.finalUrl) | $(ConvertTo-ReportCell $result.screenshot) |")
  }
  $lines | Set-Content -Path $resultMarkdown -Encoding UTF8

  [pscustomobject]@{
    Json = $resultJson
    Markdown = $resultMarkdown
  }
}

function Get-NewestRunDirectory {
  param(
    [string]$Root,
    [datetime]$MinLastWriteTime
  )

  if (-not (Test-Path -Path $Root)) {
    return $null
  }

  Get-ChildItem -Path $Root -Directory |
    Where-Object { $_.LastWriteTime -ge $MinLastWriteTime } |
    Sort-Object -Property LastWriteTime -Descending |
    Select-Object -First 1
}

function Write-InfrastructureFailureReport {
  param(
    [string]$Root,
    [string]$ConfigPath,
    [datetime]$RunStartedAt,
    [string]$Reason
  )

  $runDir = Get-NewestRunDirectory -Root $Root -MinLastWriteTime $RunStartedAt
  if (-not $runDir) {
    $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runDirPath = Join-Path $Root $runStamp
    New-Item -ItemType Directory -Path $runDirPath -Force | Out-Null
    $runDir = Get-Item -Path $runDirPath
  }

  $cleanReason = if ([string]::IsNullOrWhiteSpace($Reason)) {
    "Check-in failed before result.json was created."
  }
  else {
    (($Reason -replace "\r?\n", " ") -replace "\s{2,}", " ").Trim()
  }

  $results = New-Object System.Collections.Generic.List[object]
  $config = $null
  if (Test-Path -Path $ConfigPath) {
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  }

  $linuxUrl = if ($config -and $config.linuxDo -and $config.linuxDo.url) { $config.linuxDo.url } else { "https://linux.do/" }
  $results.Add((New-ReportItem -Name "linux.do" -Url $linuxUrl -Status "failed" -Reason $cleanReason))

  if ($config -and $config.sites) {
    foreach ($site in $config.sites) {
      $status = if (($site.PSObject.Properties.Name -contains "manualReminderOnly") -and $site.manualReminderOnly) {
        "manual_reminder"
      }
      else {
        "unknown"
      }
      $siteReason = if ($status -eq "manual_reminder") {
        "Manual reminder only; site was not opened because check-in infrastructure failed."
      }
      else {
        "Site was not processed because check-in infrastructure failed before site processing."
      }
      $results.Add((New-ReportItem -Name $site.name -Url $site.url -Status $status -Reason $siteReason))
    }
  }

  Write-ResultFiles -RunDir $runDir.FullName -Results $results.ToArray() -DryRun $false
}

function Get-ManualReminderItems {
  param([string]$ResultJson)

  $results = Get-Content -Path $ResultJson -Raw -Encoding UTF8 | ConvertFrom-Json
  @($results | Where-Object {
      $manualReminderSiteNames -contains $_.name -and
      $manualReminderStatuses -contains $_.status
    })
}

function Cleanup-ReportDirectories {
  param(
    [string]$Root,
    [switch]$KeepReports
  )

  if ($KeepReports) {
    Write-Host "Keeping report directories because -KeepReports is set."
    return [pscustomobject]@{
      Enabled = $false
      Removed = 0
      Root = $Root
    }
  }

  if (-not (Test-Path -Path $Root)) {
    return [pscustomobject]@{
      Enabled = $true
      Removed = 0
      Root = $Root
    }
  }

  $resolvedRoot = (Resolve-Path -Path $Root).Path
  $workspaceRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path
  if (-not $resolvedRoot.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean reports outside workspace: $resolvedRoot"
  }

  $removedDirectories = 0
  Get-ChildItem -Path $resolvedRoot -Directory | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
    $removedDirectories += 1
  }
  $removedFiles = 0
  Get-ChildItem -Path $resolvedRoot -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force
    $removedFiles += 1
  }

  Write-Host "Cleaned $removedDirectories report director$(if ($removedDirectories -eq 1) { 'y' } else { 'ies' }) and $removedFiles file$(if ($removedFiles -eq 1) { '' } else { 's' }) under $resolvedRoot."
  [pscustomobject]@{
    Enabled = $true
    Removed = $removedDirectories + $removedFiles
    RemovedDirectories = $removedDirectories
    RemovedFiles = $removedFiles
    Root = $resolvedRoot
  }
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
    $output | ForEach-Object { Write-Host $_ }
    return $exitCode
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

$dailyScript = Join-Path $PSScriptRoot "daily-checkin.ps1"
$mailScript = Join-Path $PSScriptRoot "send_reminder_email.py"
$checkinExitCode = 0
$runStartedAt = Get-Date

if (-not $SkipCheckin) {
  Write-Host "Running bb-browser daily check-in..."
  $checkinOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $dailyScript -ConfigPath $ConfigPath -BbTimeoutSeconds $BbTimeoutSeconds 2>&1
  $checkinExitCode = $LASTEXITCODE
  $checkinOutput | ForEach-Object { Write-Host $_ }
  if ($checkinExitCode -ne 0) {
    Write-Warning "daily-checkin.ps1 exited with code $checkinExitCode; continuing to inspect the newest report."
    try {
      $null = Get-NewestResultJson -Root $ReportsDir -MinLastWriteTime $runStartedAt
    }
    catch {
      $failureReport = Write-InfrastructureFailureReport -Root $ReportsDir -ConfigPath $ConfigPath -RunStartedAt $runStartedAt -Reason ($checkinOutput | Out-String)
      Write-Warning "Wrote infrastructure failure report: $($failureReport.Markdown)"
    }
  }
}
else {
  Write-Host "Skipping check-in run; reading newest report..."
}

$resultJson = if ($SkipCheckin) {
  Get-NewestResultJson -Root $ReportsDir
}
else {
  Get-NewestResultJson -Root $ReportsDir -MinLastWriteTime $runStartedAt
}
$resultMarkdown = [System.IO.Path]::ChangeExtension($resultJson, ".md")
$manualItems = @(Get-ManualReminderItems -ResultJson $resultJson)
$emailState = "not_needed"

if ($NoEmail) {
  $emailState = "skipped_by_flag"
  Write-Host "Email summary skipped because -NoEmail is set."
}
else {
  $emailArgs = @($mailScript, "--result-json", $resultJson)
  if ($DryRunEmail) {
    $emailArgs += "--dry-run"
    $emailState = "dry_run"
  }
  else {
    $emailState = "sent"
  }

  Write-Host "Calling HTML MIME summary email script..."
  $mailExitCode = Invoke-PythonUtf8 -Arguments $emailArgs
  if ($mailExitCode -ne 0) {
    throw "send_reminder_email.py exited with code $mailExitCode. Check CHECKIN_SMTP_HOST, CHECKIN_SMTP_PORT, CHECKIN_SMTP_USER, CHECKIN_SMTP_PASS, CHECKIN_MAIL_TO, and CHECKIN_SMTP_PROXY."
  }
}

$summary = [pscustomobject]@{
  resultJson = $resultJson
  resultMarkdown = $resultMarkdown
  manualReminderCount = $manualItems.Count
  manualReminderSites = @($manualItems | ForEach-Object { $_.name })
  email = $emailState
  smtpUserConfigured = -not [string]::IsNullOrWhiteSpace($env:CHECKIN_SMTP_USER)
  smtpProxyConfigured = -not [string]::IsNullOrWhiteSpace($env:CHECKIN_SMTP_PROXY)
  cleanup = $null
}

$summary.cleanup = Cleanup-ReportDirectories -Root $ReportsDir -KeepReports:$KeepReports
$summary | ConvertTo-Json -Depth 4

if ($checkinExitCode -ne 0) {
  exit $checkinExitCode
}
