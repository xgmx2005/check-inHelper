# bb-browser daily check-in

This workspace contains a small daily check-in runner for Linux.do OAuth based public-service AI sites.

## First-time setup

Login once in the bb-browser managed Chrome window:

```powershell
bb-browser.cmd open https://linux.do/
```

Then open each site once and finish any Linux.do authorization prompts:

```powershell
bb-browser.cmd open https://muyuan.do
bb-browser.cmd open https://newapi.linuxdo.edu.rs
bb-browser.cmd open https://new-api.abrdns.com/
bb-browser.cmd open https://ai.huaibao.top/
bb-browser.cmd open https://elysiver.h-e.top/
bb-browser.cmd open https://lpgpt.us/
```

## Manual dry run

Dry run checks pages and button matching without clicking the final check-in button:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-checkin.ps1 -DryRun
```

Run one site while debugging:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-checkin.ps1 -OnlySite lpgpt
```

## Manual real run

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\daily-checkin.ps1
```

Reports are written to `reports/<timestamp>/result.md`, with failure screenshots in the same folder.

## Agent entrypoint

Use this command from Codex, Claude, Cursor, or any other local agent:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-agent-checkin.ps1
```

It runs `daily-checkin.ps1`, reads the newest `reports/<timestamp>/result.json`, and calls `scripts/send_reminder_email.py` to send the full daily status summary.
The result files and screenshots are treated as temporary mail input. By default, the entrypoint cleans report directories after the email/summary path finishes so old reports do not accumulate on disk. Use `-KeepReports` only when debugging and you need to inspect local files.

## Windows tray app

Double-click the launcher in this workspace:

```text
launch-checkin-tray.cmd
```

Or create a desktop shortcut:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\create-checkin-tray-shortcut.ps1
```

Start the lightweight tray controller manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\checkin-tray.ps1
```

The tray menu can run check-in now, open settings, open Linux.do login, send a test email, clean temporary reports, and exit. Double-click the tray icon to open settings.
When the tray app starts, it opens the settings window immediately instead of hiding only in the tray. Starting a manual check-in asks for confirmation. Closing the settings window asks whether to keep running in the tray, exit the app, or cancel. Exiting from the tray menu also asks for confirmation.

Settings are stored in `config/tray-settings.json`. This file only stores non-secret preferences such as daily run time, whether Windows startup is enabled, report retention, and per-site enable/manual-reminder settings. SMTP passwords are not stored there; keep using `CHECKIN_SMTP_PASS` and the other `CHECKIN_*` environment variables.

Windows startup is off by default. If enabled in the settings window, the tray app creates a shortcut only in the current user's Startup folder. It does not write machine-wide startup settings.

To validate the tray script without launching the UI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\checkin-tray.ps1 -ValidateOnly
```

To test the email rendering without sending SMTP mail:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-agent-checkin.ps1 -SkipCheckin -DryRunEmail
```

For real HTML email sending, the agent only needs normal environment variables, not a Codex-specific Gmail connector:

```powershell
setx CHECKIN_MAIL_TO "2463323447@qq.com"
setx CHECKIN_SMTP_HOST "smtp.gmail.com"
setx CHECKIN_SMTP_PORT "587"
setx CHECKIN_SMTP_USER "your-gmail-address@gmail.com"
setx CHECKIN_SMTP_PASS "your-gmail-app-password"
setx CHECKIN_MAIL_FROM "your-gmail-address@gmail.com"
```

If SMTP must go through Clash Verge, also set:

```powershell
setx CHECKIN_SMTP_PROXY "http://127.0.0.1:7897"
```

Open a new terminal after `setx` so Claude/Codex can see the variables. Claude can run the same entrypoint as long as its runtime can reach the SMTP server.

## Failure notification

`run-agent-checkin.ps1` sends the newest result summary through `scripts/send_reminder_email.py` unless `-NoEmail` is set. Sites with `emailOnFailure: true` or `manualReminderOnly: true` remain useful as status markers, but the email now includes every site result.

`daily-checkin.ps1` itself does not send SMTP mail by default. SMTP from that lower-level script is only a fallback for local manual use; enable it explicitly with `CHECKIN_ENABLE_SMTP=1` and configure the rest through environment variables. Do not put secrets in this repo:

```powershell
setx CHECKIN_ENABLE_SMTP "1"
setx CHECKIN_MAIL_TO "you@example.com"
setx CHECKIN_SMTP_HOST "smtp.example.com"
setx CHECKIN_SMTP_PORT "587"
setx CHECKIN_SMTP_USER "smtp-user@example.com"
setx CHECKIN_SMTP_PASS "your-app-password"
setx CHECKIN_MAIL_FROM "smtp-user@example.com"
```

Open a new terminal after `setx` so the variables take effect.

## Configuration

Edit `config/checkin-sites.json` to add sites or tune button/success keywords.

For New API-style sites, the script navigates to `/console/personal` first, then clicks the real check-in button such as `立即签到`. Generic quota text is not treated as a successful check-in.

Sites with `manualReminderOnly: true` are not opened by the script. They are written to the report as `manual_reminder` so the Codex automation can send a Gmail reminder instead. `muyuan` and `lpgpt` currently use this mode.

For designed summary emails, use `scripts/send_reminder_email.py`. It follows the SMTP/MIME pattern used by the training monitor script: the email is sent as `multipart/alternative` with both `text/plain` and real `text/html` parts. The email includes the full site status list so the mailbox is the durable summary. The Gmail connector path is a fallback only; it sends reliable plain text but does not reliably render HTML/CSS styling.

Run the local guard test after changing the config or script:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-checkin-config.ps1
python .\scripts\test_reminder_email.py
```

The script never stores passwords. It only reuses the login state inside the bb-browser managed Chrome profile.
