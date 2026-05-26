param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\checkin-sites.json"),
  [string]$OutputDir = (Join-Path $PSScriptRoot "..\reports"),
  [string]$BbBrowser = "bb-browser.cmd",
  [string[]]$OnlySite = @(),
  [int]$BbTimeoutSeconds = 60,
  [switch]$DryRun,
  [switch]$DebugJs
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Invoke-Bb {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [int]$TimeoutSeconds = $script:BbTimeoutSeconds
  )

  $job = Start-Job -ScriptBlock {
    param(
      [string]$Command,
      [string[]]$BaseArgs,
      [string[]]$ExtraArgs
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom

    $output = & $Command @BaseArgs @ExtraArgs 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
      ExitCode = $exitCode
      Text = ($output | Out-String).Trim()
    }
  } -ArgumentList $script:BbBrowserCommand, $script:BbBrowserBaseArgs, $Args

  if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      ExitCode = 124
      Text = "bb-browser command timed out after ${TimeoutSeconds}s: $($Args -join ' ')"
    }
  }

  $result = Receive-Job -Job $job
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

  if ($result) {
    return ($result | Select-Object -Last 1)
  }

  [pscustomobject]@{
    ExitCode = 1
    Text = "bb-browser command returned no output: $($Args -join ' ')"
  }
}

function Resolve-BbBrowserInvocation {
  param([string]$Command)

  $resolved = Get-Command $Command -ErrorAction Stop
  if ($resolved.Source -and $resolved.Source.EndsWith(".cmd", [System.StringComparison]::OrdinalIgnoreCase)) {
    $cliPath = Join-Path (Split-Path $resolved.Source -Parent) "node_modules\bb-browser\dist\cli.js"
    if (Test-Path $cliPath) {
      $nodePath = (Get-Command node -ErrorAction Stop).Source
      return [pscustomobject]@{
        Command = $nodePath
        BaseArgs = @($cliPath)
      }
    }
  }

  return [pscustomobject]@{
    Command = $resolved.Source
    BaseArgs = @()
  }
}

function ConvertFrom-EmbeddedJson {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    throw "No JSON text returned."
  }

  $start = $Text.IndexOf("{")
  $end = $Text.LastIndexOf("}")
  if ($start -lt 0 -or $end -lt $start) {
    throw "Could not find JSON object in: $Text"
  }

  $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

function ConvertTo-JsArray {
  param([object[]]$Values)
  $items = foreach ($value in $Values) {
    $escaped = ([string]$value) -replace "\\", "\\" -replace "'", "\'"
    "'$escaped'"
  }
  "[" + ($items -join ",") + "]"
}

function Compress-Js {
  param([string]$JavaScript)
  (($JavaScript -replace "\r?\n\s*", " ") -replace "\s{2,}", " ").Trim()
}

function Test-TextContainsAny {
  param(
    [string]$Text,
    [object[]]$Keywords
  )

  foreach ($keyword in $Keywords) {
    if ($Text -match [regex]::Escape([string]$keyword)) {
      return $true
    }
  }

  return $false
}

function Test-ControlContainsAny {
  param(
    [object[]]$Controls,
    [object[]]$Keywords
  )

  foreach ($control in $Controls) {
    foreach ($keyword in $Keywords) {
      if ([string]$control.text -match [regex]::Escape([string]$keyword)) {
        return $true
      }
    }
  }

  return $false
}

function Test-StateAtCheckinArea {
  param(
    [object]$State,
    [object]$Config
  )

  if (-not $State) {
    return $false
  }

  $keywords = @()
  if ($Config.defaults.PSObject.Properties.Name -contains "checkinAreaKeywords") {
    $keywords += @($Config.defaults.checkinAreaKeywords)
  }

  Test-TextContainsAny -Text $State.text -Keywords $keywords
}

function Get-PageState {
  $js = @"
(() => {
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const controls = Array.from(document.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]'))
    .map((el, index) => ({
      index,
      tag: el.tagName,
      text: normalize(el.innerText || el.value || el.getAttribute('aria-label') || el.title),
      href: el.href || '',
      disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
      visible: !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)
    }))
    .filter((item) => item.text || item.href);

  return JSON.stringify({
    href: location.href,
    title: document.title,
    text: normalize(document.body ? document.body.innerText : '').slice(0, 24000),
    controls: controls.slice(0, 200)
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  if ($DebugJs) {
    Write-Host "DEBUG Get-PageState JS:"
    Write-Host $js
  }
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser eval failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Wait-PageReady {
  param(
    [int]$TimeoutSeconds = 25,
    [int]$PollSeconds = 2
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastState = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $lastState = Get-PageState
    $visibleControls = @($lastState.controls | Where-Object { $_.visible -and $_.text }).Count
    $hasEnoughText = ([string]$lastState.text).Length -gt 120
    $stillLoading = ([string]$lastState.text) -match "加载中|Loading|loading"

    if ($hasEnoughText -and $visibleControls -ge 3 -and -not $stillLoading) {
      return $lastState
    }
  }

  if ($lastState) {
    return $lastState
  }

  Get-PageState
}

function Wait-PageChanged {
  param(
    [string]$PreviousHref,
    [int]$TimeoutSeconds = 15
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastState = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $lastState = Get-PageState
    if ($lastState.href -ne $PreviousHref -or $lastState.href -match "connect\.linux\.do" -or $lastState.title -match "LINUX DO Connect") {
      return $lastState
    }
  }

  if ($lastState) {
    return $lastState
  }

  Get-PageState
}

function Invoke-ClickByKeywords {
  param(
    [object[]]$Keywords,
    [switch]$DryRun
  )

  $keywordJson = ConvertTo-JsArray -Values $Keywords
  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(() => {
  const keywords = $keywordJson.map((value) => String(value).toLowerCase());
  const dryRun = $dryRunLiteral;
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const isVisible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const controls = Array.from(document.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]'));
  const candidates = controls
    .map((el) => ({
      el,
      tag: el.tagName,
      text: normalize(el.innerText || el.value || el.getAttribute('aria-label') || el.title),
      href: el.href || '',
      disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
      visible: isVisible(el)
    }))
    .filter((item) => item.visible && !item.disabled && item.text);

  let hit = null;
  for (const keyword of keywords) {
    const matches = candidates.filter((item) => item.text.toLowerCase().includes(keyword));
    hit = matches.find((item) => item.href) || matches[0] || null;
    if (hit) break;
  }

  if (hit && !dryRun) {
    if (hit.href && hit.el.tagName === 'A') {
      location.href = hit.href;
    } else {
      hit.el.scrollIntoView({ block: 'center', inline: 'center' });
      hit.el.click();
    }
  }

  return JSON.stringify({
    clicked: !!hit && !dryRun,
    matched: !!hit,
    dryRun,
    text: hit ? hit.text : '',
    tag: hit ? hit.tag : '',
    href: location.href
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  if ($DebugJs) {
    Write-Host "DEBUG Invoke-ClickByKeywords JS:"
    Write-Host $js
  }
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser click-by-keywords failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-NavigateToFirstPath {
  param(
    [object[]]$Paths,
    [switch]$DryRun
  )

  $pathJson = ConvertTo-JsArray -Values $Paths
  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(() => {
  const paths = $pathJson;
  const dryRun = $dryRunLiteral;
  const path = paths.map((value) => String(value || '').trim()).find((value) => value.startsWith('/'));
  if (!path) {
    return JSON.stringify({ matched: false, clicked: false, dryRun, href: location.href, text: '' });
  }

  const target = location.origin + path;
  if (!dryRun && location.href !== target) {
    location.href = target;
  }

  return JSON.stringify({
    matched: true,
    clicked: !dryRun,
    dryRun,
    href: target,
    text: path
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser navigate-to-path failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-OpenLikelyUserMenu {
  param([switch]$DryRun)

  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(() => {
  const dryRun = $dryRunLiteral;
  const isVisible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const normalize = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const controls = Array.from(document.querySelectorAll('button,a,[role=button]'))
    .map((el) => ({ el, text: normalize(el.innerText || el.getAttribute('aria-label') || el.title), rect: el.getBoundingClientRect(), disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true', visible: isVisible(el) }))
    .filter((item) => item.visible && !item.disabled && item.rect.top >= 0 && item.rect.top < 160 && item.rect.left > window.innerWidth * 0.6);

  const hit = controls
    .sort((a, b) => b.rect.right - a.rect.right || b.rect.width - a.rect.width)[0] || null;

  if (hit && !dryRun) {
    hit.el.scrollIntoView({ block: 'center', inline: 'center' });
    hit.el.click();
  }

  return JSON.stringify({
    matched: !!hit,
    clicked: !!hit && !dryRun,
    dryRun,
    text: hit ? hit.text : '',
    href: location.href
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser open-user-menu failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-OAuthApprove {
  param([switch]$DryRun)

  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(() => {
  const dryRun = $dryRunLiteral;
  const link = Array.from(document.querySelectorAll('a')).find((el) => (el.href || '').includes('/oauth2/approve/'));
  if (link && !dryRun) {
    location.href = link.href;
  }
  return JSON.stringify({
    matched: !!link,
    clicked: !!link && !dryRun,
    text: link ? (link.innerText || link.textContent || '').trim() : '',
    href: link ? link.href : '',
    dryRun
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser oauth approve failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-StartLinuxDoOAuth {
  param([switch]$DryRun)

  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(async () => {
  const dryRun = $dryRunLiteral;
  let status = {};
  try {
    status = JSON.parse(localStorage.getItem('status') || '{}');
  } catch (error) {}

  const clientId = status.linuxdo_client_id || '';
  if (!clientId) {
    return JSON.stringify({ matched: false, clicked: false, dryRun, reason: 'missing linuxdo_client_id', href: location.href });
  }

  const response = await fetch('/api/oauth/state', { credentials: 'include', cache: 'no-store' });
  const payload = await response.json();
  if (!payload || !payload.success || !payload.data) {
    return JSON.stringify({ matched: false, clicked: false, dryRun, reason: 'missing oauth state', href: location.href });
  }

  const state = String(payload.data) + '|' + btoa(location.host);
  const target = 'https://connect.linux.do/oauth2/authorize?response_type=code&client_id=' + encodeURIComponent(clientId) + '&state=' + encodeURIComponent(state);
  if (!dryRun) {
    location.href = target;
  }

  return JSON.stringify({
    matched: true,
    clicked: !dryRun,
    dryRun,
    text: 'LinuxDO OAuth',
    href: target
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser linuxdo oauth fallback failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-AgreeVisibleCheckbox {
  param([switch]$DryRun)

  $dryRunLiteral = if ($DryRun) { "true" } else { "false" }
  $js = @"
(() => {
  const dryRun = $dryRunLiteral;
  const isVisible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const boxes = Array.from(document.querySelectorAll('input[type=checkbox],[role=checkbox]'))
    .filter((el) => isVisible(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true');
  const unchecked = boxes.find((el) => !(el.checked || el.getAttribute('aria-checked') === 'true'));
  if (unchecked && !dryRun) {
    unchecked.click();
  }
  return JSON.stringify({
    matched: !!unchecked,
    clicked: !!unchecked && !dryRun,
    dryRun
  });
})()
"@

  $js = Compress-Js -JavaScript $js
  $result = Invoke-Bb -Args @("eval", $js)
  if ($result.ExitCode -ne 0) {
    throw "bb-browser checkbox agreement failed: $($result.Text)"
  }

  ConvertFrom-EmbeddedJson -Text $result.Text
}

function Invoke-ClosePopups {
  param([object]$Config)

  for ($i = 0; $i -lt 2; $i++) {
    $state = Get-PageState
    if (-not (Test-ControlContainsAny -Controls $state.controls -Keywords $Config.defaults.popupCloseKeywords)) {
      return
    }

    $click = Invoke-ClickByKeywords -Keywords $Config.defaults.popupCloseKeywords -DryRun:$DryRun
    if (-not $click.matched -or $DryRun) {
      return
    }

    $null = Wait-PageReady -TimeoutSeconds 8 -PollSeconds 1
  }
}

function Invoke-LinuxDoAuthorization {
  param([object]$Config)

  for ($i = 0; $i -lt [int]$Config.defaults.maxAuthorizationClicks; $i++) {
    $state = Get-PageState
    $isAuthorizationPage = ($state.href -match "connect\.linux\.do") -or
      ($state.title -match "LINUX DO Connect") -or
      (Test-ControlContainsAny -Controls $state.controls -Keywords $Config.defaults.authorizationKeywords)

    if (-not $isAuthorizationPage) {
      return $state
    }

    $authClick = if ($state.href -match "connect\.linux\.do") {
      Invoke-OAuthApprove -DryRun:$DryRun
    } else {
      Invoke-ClickByKeywords -Keywords $Config.defaults.authorizationKeywords -DryRun:$DryRun
    }
    if (-not $authClick.matched -or $DryRun) {
      return $state
    }

    $null = Wait-PageReady -TimeoutSeconds 15 -PollSeconds 2
  }

  Get-PageState
}

function Invoke-SiteLogin {
  param([object]$Config)

  Invoke-ClosePopups -Config $Config

  for ($i = 0; $i -lt [int]$Config.defaults.maxAuthorizationClicks; $i++) {
    $state = Get-PageState
    $hasLoginControl = Test-ControlContainsAny -Controls $state.controls -Keywords $Config.defaults.siteLoginKeywords
    if (-not $hasLoginControl) {
      return $state
    }

    $null = Invoke-AgreeVisibleCheckbox -DryRun:$DryRun
    $loginClick = Invoke-ClickByKeywords -Keywords $Config.defaults.siteLoginKeywords -DryRun:$DryRun
    if (-not $loginClick.matched -or $DryRun) {
      return $state
    }

    $previousHref = $state.href
    $state = Wait-PageChanged -PreviousHref $previousHref -TimeoutSeconds 15
    if ($state.href -eq $previousHref -and (Test-ControlContainsAny -Controls $state.controls -Keywords @("LinuxDO", "Linux.do"))) {
      $oauth = Invoke-StartLinuxDoOAuth -DryRun:$DryRun
      if ($oauth.matched -and -not $DryRun) {
        $state = Wait-PageChanged -PreviousHref $previousHref -TimeoutSeconds 15
      }
    }

    $state = Invoke-LinuxDoAuthorization -Config $Config
    Invoke-ClosePopups -Config $Config
  }

  Get-PageState
}

function Invoke-NavigateToPersonalSettings {
  param(
    [object]$Config,
    [object]$InitialState
  )

  $state = $InitialState
  if (Test-StateAtCheckinArea -State $state -Config $Config) {
    return $state
  }

  $paths = @()
  if ($Config.defaults.PSObject.Properties.Name -contains "personalSettingsPaths") {
    $paths += @($Config.defaults.personalSettingsPaths)
  }

  if ($paths.Count -gt 0) {
    $direct = Invoke-NavigateToFirstPath -Paths $paths -DryRun:$DryRun
    if ($direct.matched -and -not $DryRun) {
      $state = Wait-PageReady -TimeoutSeconds 20 -PollSeconds 2
      $state = Invoke-LinuxDoAuthorization -Config $Config
      $state = Invoke-SiteLogin -Config $Config
      if (Test-StateAtCheckinArea -State $state -Config $Config) {
        return $state
      }
    }
  }

  foreach ($keyword in $Config.defaults.postLoginNavigationKeywords) {
    $state = Get-PageState
    if (-not (Test-ControlContainsAny -Controls $state.controls -Keywords @($keyword))) {
      continue
    }

    $navClick = Invoke-ClickByKeywords -Keywords @($keyword) -DryRun:$DryRun
    if (-not $navClick.matched -or $DryRun) {
      continue
    }

    $state = Wait-PageReady -TimeoutSeconds 15 -PollSeconds 2
    if (Test-StateAtCheckinArea -State $state -Config $Config) {
      return $state
    }
  }

  $menuClick = Invoke-OpenLikelyUserMenu -DryRun:$DryRun
  if ($menuClick.matched -and -not $DryRun) {
    Start-Sleep -Seconds 1
    $navClick = Invoke-ClickByKeywords -Keywords $Config.defaults.postLoginNavigationKeywords -DryRun:$DryRun
    if ($navClick.matched) {
      $state = Wait-PageReady -TimeoutSeconds 15 -PollSeconds 2
      if (Test-StateAtCheckinArea -State $state -Config $Config) {
        return $state
      }
    }
  }

  Get-PageState
}

function Find-And-ClickCheckin {
  param(
    [object]$Config,
    [object]$InitialState
  )

  $state = Invoke-NavigateToPersonalSettings -Config $Config -InitialState $InitialState
  Invoke-ClosePopups -Config $Config

  $click = Invoke-ClickByKeywords -Keywords $Config.defaults.buttonKeywords -DryRun:$DryRun
  if ($click.matched) {
    return [pscustomobject]@{
      Matched = $true
      Click = $click
      State = $state
    }
  }

  [pscustomobject]@{
    Matched = $false
    Click = $click
    State = (Get-PageState)
  }
}

function Save-FailureScreenshot {
  param(
    [string]$RunDir,
    [string]$Name
  )

  $safeName = $Name -replace "[^a-zA-Z0-9._-]", "-"
  $path = Join-Path $RunDir "$safeName.png"
  $result = Invoke-Bb -Args @("screenshot", $path)
  if ($result.ExitCode -ne 0) {
    return "screenshot failed: $($result.Text)"
  }

  return $path
}

function New-Result {
  param(
    [string]$Name,
    [string]$Url,
    [string]$Status,
    [string]$Reason,
    [object]$State,
    [string]$Screenshot = ""
  )

  [pscustomobject]@{
    name = $Name
    url = $Url
    status = $Status
    reason = $Reason
    finalUrl = if ($State) { $State.href } else { "" }
    title = if ($State) { $State.title } else { "" }
    screenshot = $Screenshot
    timestamp = (Get-Date).ToString("s")
  }
}

function Write-Report {
  param(
    [string]$RunDir,
    [object[]]$Results,
    [bool]$DryRun
  )

  $jsonPath = Join-Path $RunDir "result.json"
  $mdPath = Join-Path $RunDir "result.md"
  $Results | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

  $lines = @()
  $lines += "# Daily check-in report"
  $lines += ""
  $lines += "- Time: $(Get-Date -Format s)"
  $lines += "- Dry run: $DryRun"
  $lines += ""
  $lines += "| Site | Status | Reason | Final URL | Screenshot |"
  $lines += "| --- | --- | --- | --- | --- |"
  foreach ($item in $Results) {
    $screenshot = if ($item.screenshot) { $item.screenshot } else { "" }
    $reason = ($item.reason -replace "\|", "/")
    $lines += "| $($item.name) | $($item.status) | $reason | $($item.finalUrl) | $screenshot |"
  }

  $lines | Set-Content -Path $mdPath -Encoding UTF8
  [pscustomobject]@{
    Json = $jsonPath
    Markdown = $mdPath
  }
}

function Send-EmailNotifications {
  param(
    [object]$Config,
    [object[]]$Results,
    [object]$Report
  )

  try {
  if ($env:CHECKIN_ENABLE_SMTP -ne "1") {
    return
  }

  $smtpHost = $env:CHECKIN_SMTP_HOST
  $mailTo = $env:CHECKIN_MAIL_TO
  if ([string]::IsNullOrWhiteSpace($smtpHost) -or [string]::IsNullOrWhiteSpace($mailTo)) {
    return
  }

  $notifySiteNames = @(
    $Config.sites |
      Where-Object { ($_.PSObject.Properties.Name -contains "emailOnFailure") -and $_.emailOnFailure } |
      ForEach-Object { $_.name }
  )
  if ($notifySiteNames.Count -eq 0) {
    return
  }

  $notifyStatuses = @("failed", "unknown", "network_error")
  $items = @($Results | Where-Object { $notifySiteNames -contains $_.name -and $notifyStatuses -contains $_.status })
  if ($items.Count -eq 0) {
    return
  }

  $smtpPort = if ($env:CHECKIN_SMTP_PORT) { [int]$env:CHECKIN_SMTP_PORT } else { 587 }
  $mailFrom = if ($env:CHECKIN_MAIL_FROM) { $env:CHECKIN_MAIL_FROM } elseif ($env:CHECKIN_SMTP_USER) { $env:CHECKIN_SMTP_USER } else { $mailTo }
  $subject = "Check-in alert: manual action needed for " + (($items | ForEach-Object { "$($_.name)=$($_.status)" }) -join ", ")
  $bodyLines = @()
  $bodyLines += "Manual action is needed for these sites:"
  $bodyLines += ""
  foreach ($item in $items) {
    $bodyLines += "- $($item.name): $($item.status)"
    $bodyLines += "  URL: $($item.url)"
    $bodyLines += "  Final URL: $($item.finalUrl)"
    $bodyLines += "  Reason: $($item.reason)"
    if ($item.screenshot) {
      $bodyLines += "  Screenshot: $($item.screenshot)"
    }
    $bodyLines += ""
  }
  $bodyLines += "Report: $($Report.Markdown)"
  $body = $bodyLines -join [Environment]::NewLine

  if ($env:CHECKIN_SMTP_PROXY) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
      Write-Warning "CHECKIN_SMTP_PROXY is set but curl.exe was not found; falling back to SmtpClient."
    } else {
      $mailFile = Join-Path ([System.IO.Path]::GetTempPath()) ("bb-checkin-mail-" + [guid]::NewGuid() + ".eml")
      try {
        @(
          "From: <$mailFrom>",
          "To: <$mailTo>",
          "Subject: $subject",
          "Content-Type: text/plain; charset=utf-8",
          "",
          $body
        ) | Set-Content -Path $mailFile -Encoding UTF8

        $smtpUrl = if ($smtpPort -eq 465) { "smtps://$smtpHost`:$smtpPort" } else { "smtp://$smtpHost`:$smtpPort" }
        & $curl.Source --silent --show-error --ssl-reqd --proxy $env:CHECKIN_SMTP_PROXY --url $smtpUrl --mail-from $mailFrom --mail-rcpt $mailTo --user "$($env:CHECKIN_SMTP_USER):$($env:CHECKIN_SMTP_PASS)" --upload-file $mailFile
        if ($LASTEXITCODE -eq 0) {
          Write-Host "Email notification sent to $mailTo via proxy $($env:CHECKIN_SMTP_PROXY)"
          return
        }

        Write-Warning "curl SMTP send failed with exit code $LASTEXITCODE; falling back to SmtpClient."
      } finally {
        Remove-Item -LiteralPath $mailFile -Force -ErrorAction SilentlyContinue
      }
    }
  }

  $message = [System.Net.Mail.MailMessage]::new()
  $message.From = [System.Net.Mail.MailAddress]::new($mailFrom)
  foreach ($addr in ($mailTo -split "[,;]")) {
    if (-not [string]::IsNullOrWhiteSpace($addr)) {
      $message.To.Add($addr.Trim())
    }
  }
  $message.Subject = $subject
  $message.Body = $body
  $message.SubjectEncoding = [System.Text.Encoding]::UTF8
  $message.BodyEncoding = [System.Text.Encoding]::UTF8

  $client = [System.Net.Mail.SmtpClient]::new($smtpHost, $smtpPort)
  $client.EnableSsl = if ($env:CHECKIN_SMTP_SSL) { $env:CHECKIN_SMTP_SSL -ne "0" } else { $true }
  if ($env:CHECKIN_SMTP_USER -and $env:CHECKIN_SMTP_PASS) {
    $client.Credentials = [System.Net.NetworkCredential]::new($env:CHECKIN_SMTP_USER, $env:CHECKIN_SMTP_PASS)
  }

  try {
    $client.Send($message)
    Write-Host "Email notification sent to $mailTo"
  } finally {
    $message.Dispose()
    $client.Dispose()
  }
  } catch {
    Write-Warning "Email notification failed and was ignored: $($_.Exception.Message)"
  }
}

$bbInvocation = Resolve-BbBrowserInvocation -Command $BbBrowser
$script:BbBrowserCommand = $bbInvocation.Command
$script:BbBrowserBaseArgs = @($bbInvocation.BaseArgs)
$script:BbTimeoutSeconds = $BbTimeoutSeconds

$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $OutputDir $runStamp
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]

$status = Invoke-Bb -Args @("status")
if ($status.Text -match "Daemon not running") {
  Write-Host "Starting bb-browser daemon..."
  $daemon = Invoke-Bb -Args @("daemon", "start")
  if ($daemon.ExitCode -ne 0) {
    throw "Could not start bb-browser daemon: $($daemon.Text)"
  }
  Start-Sleep -Seconds 3
}

Write-Host "Checking Linux.do login state..."
$openLinux = Invoke-Bb -Args @("open", $config.linuxDo.url)
if ($openLinux.ExitCode -ne 0) {
  throw "Could not open Linux.do: $($openLinux.Text)"
}

$linuxState = Wait-PageReady -TimeoutSeconds 25 -PollSeconds 2
$needsLogin = Test-TextContainsAny -Text $linuxState.text -Keywords $config.linuxDo.loginRequiredKeywords
$hasLoggedInHint = Test-TextContainsAny -Text $linuxState.text -Keywords $config.linuxDo.loggedInKeywords

if (-not $hasLoggedInHint -and $needsLogin) {
  $shot = Save-FailureScreenshot -RunDir $runDir -Name "linux-do-login-required"
  $results.Add((New-Result -Name "linux.do" -Url $config.linuxDo.url -Status "failed" -Reason "Linux.do login is required. Please login in the bb-browser Chrome window first." -State $linuxState -Screenshot $shot))
  $report = Write-Report -RunDir $runDir -Results $results.ToArray() -DryRun ([bool]$DryRun)
  Write-Host "Linux.do login is required. Report: $($report.Markdown)"
  exit 2
}

$results.Add((New-Result -Name "linux.do" -Url $config.linuxDo.url -Status "ok" -Reason "Linux.do login precheck passed." -State $linuxState))

$sitesToRun = @($config.sites)
if ($OnlySite.Count -gt 0) {
  $sitesToRun = @($config.sites | Where-Object { $OnlySite -contains $_.name })
  if ($sitesToRun.Count -eq 0) {
    throw "No site matched -OnlySite: $($OnlySite -join ', ')"
  }
}

foreach ($site in $sitesToRun) {
  if (($site.PSObject.Properties.Name -contains "manualReminderOnly") -and $site.manualReminderOnly) {
    Write-Host "Skipping $($site.name) <$($site.url)>; manual reminder only."
    $results.Add((New-Result -Name $site.name -Url $site.url -Status "manual_reminder" -Reason "Manual reminder only; site was not opened by automation." -State ([pscustomobject]@{
      href = $site.url
      title = ""
      text = ""
      controls = @()
    })))
    $null = Write-Report -RunDir $runDir -Results $results.ToArray() -DryRun ([bool]$DryRun)
    continue
  }

  Write-Host "Processing $($site.name) <$($site.url)>..."
  $state = $null
  try {
    $openSite = Invoke-Bb -Args @("open", $site.url)
    if ($openSite.ExitCode -ne 0) {
      throw "open failed: $($openSite.Text)"
    }

    $state = Wait-PageReady -TimeoutSeconds 25 -PollSeconds 2
    $state = Invoke-LinuxDoAuthorization -Config $config
    $state = Invoke-SiteLogin -Config $config

    if ($state.href -match "^chrome-error://" -or $state.text -match "无法访问此网站|ERR_CONNECTION|检查代理服务器和防火墙") {
      $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-network-error"
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "network_error" -Reason "Chrome showed a network error page." -State $state -Screenshot $shot))
      continue
    }

    if (Test-TextContainsAny -Text $state.text -Keywords $config.defaults.failureKeywords) {
      $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-failure"
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "failed" -Reason "Page contains a failure/login/captcha keyword." -State $state -Screenshot $shot))
      continue
    }

    $checkin = Find-And-ClickCheckin -Config $config -InitialState $state
    $click = $checkin.Click
    $state = $checkin.State
    if (-not $checkin.Matched) {
      if (Test-TextContainsAny -Text $state.text -Keywords $config.defaults.successKeywords) {
        $results.Add((New-Result -Name $site.name -Url $site.url -Status "already_done" -Reason "Already-done keyword is visible after personal settings navigation." -State $state))
        continue
      }

      $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-no-button"
      $controls = ($state.controls | Select-Object -First 20 | ForEach-Object { $_.text }) -join "; "
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "failed" -Reason "No check-in button matched. Visible controls: $controls" -State $state -Screenshot $shot))
      continue
    }

    if ($DryRun) {
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "dry_run" -Reason "Matched button: $($click.text)" -State $state))
      continue
    }

    $state = Wait-PageReady -TimeoutSeconds 20 -PollSeconds 2

    if (Test-TextContainsAny -Text $state.text -Keywords $config.defaults.failureKeywords) {
      $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-after-click-failure"
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "failed" -Reason "Clicked '$($click.text)', then page showed a failure/login/captcha keyword." -State $state -Screenshot $shot))
    } elseif (Test-TextContainsAny -Text $state.text -Keywords $config.defaults.successKeywords) {
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "success" -Reason "Clicked '$($click.text)' and a success/already-done keyword is visible." -State $state))
    } else {
      $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-unknown-result"
      $results.Add((New-Result -Name $site.name -Url $site.url -Status "unknown" -Reason "Clicked '$($click.text)', but no success keyword was found." -State $state -Screenshot $shot))
    }
  } catch {
    $shot = Save-FailureScreenshot -RunDir $runDir -Name "$($site.name)-exception"
    $results.Add((New-Result -Name $site.name -Url $site.url -Status "failed" -Reason $_.Exception.Message -State $state -Screenshot $shot))
  } finally {
    $null = Write-Report -RunDir $runDir -Results $results.ToArray() -DryRun ([bool]$DryRun)
  }
}

$finalReport = Write-Report -RunDir $runDir -Results $results.ToArray() -DryRun ([bool]$DryRun)
Send-EmailNotifications -Config $config -Results $results.ToArray() -Report $finalReport
Write-Host "Check-in finished."
Write-Host "Markdown report: $($finalReport.Markdown)"
Write-Host "JSON report: $($finalReport.Json)"

$failed = @($results | Where-Object { $_.status -in @("failed", "unknown", "network_error") })
if ($failed.Count -gt 0) {
  exit 1
}

exit 0
