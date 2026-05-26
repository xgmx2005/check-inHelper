# Check-in Helper App Modernization Requirements

## 1. Purpose

Check-in Helper should become a polished desktop app for managing daily Linux.do OAuth based check-ins, manual reminder sites, email summaries, and local reports.

The current PowerShell WinForms tray UI is a legacy controller. It proves the workflow, but it is not the target app experience because it renders poorly on high-DPI displays and cannot reliably match the desired modern cat-themed interface.

## 2. Product Goals

- Provide a modern desktop app with a clean, warm, cat-themed interface.
- Keep the existing check-in automation working during migration.
- Make daily status easy to understand at a glance.
- Let the user run check-in manually, manage the schedule, enable or disable sites, mark manual-reminder sites, inspect SMTP readiness, and open Linux.do login.
- Keep secrets out of project files. In Milestone 1, SMTP passwords stay in environment variables. A future credential-store migration must be designed separately.
- Ship as a real Windows desktop app with tray support and a normal installer or portable bundle.

## 3. Non-Goals

- Do not rewrite the browser automation engine in the first milestone.
- Do not replace `bb-browser` in the first milestone.
- Do not store SMTP passwords in JSON files.
- Do not build a cloud service.
- Do not add account sync, multi-user collaboration, or remote dashboards.
- Do not keep improving the PowerShell WinForms UI except for critical fixes.

## 4. Recommended Architecture

Use Tauri 2 as the desktop app shell, React + TypeScript for the UI, and a small command bridge to the existing PowerShell scripts.

```text
check-inHelper/
  apps/
    desktop/
      package.json
      src/
        app/
        components/
        features/
        styles/
      src-tauri/
        Cargo.toml
        tauri.conf.json
        src/
  packages/
    core/
      src/
        checkinTypes.ts
        settingsSchema.ts
        reportParser.ts
  config/
    checkin-sites.json
    tray-settings.json
  scripts/
    daily-checkin.ps1
    run-agent-checkin.ps1
    send_reminder_email.py
```

### Why This Stack

- Tauri gives native desktop windows, tray support, app packaging, and a smaller footprint than Electron.
- React + TypeScript makes the interface fast to iterate and test.
- Tailwind CSS is appropriate for the visual system: cards, spacing, status chips, subtle motion, and responsive layout.
- Existing PowerShell and Python scripts can remain as the legacy engine while the new app shell matures.

## 5. Target User Experience

### Main Window

The first screen should be the actual control panel, not a landing page.

Primary sections:

- Header: `Check-in Helper`, current run state, next scheduled run time, small cat assistant visual.
- Status summary: total sites, successful/ready sites, manual-reminder sites, SMTP status.
- Site table: site name, URL, enabled state, manual reminder state, latest status, latest reason.
- Schedule panel: daily run time, start with Windows, keep reports for debugging.
- Actions: run now, open Linux.do login, send test email, clean reports.
- Latest result: compact list from newest `result.json`.

### Tray Behavior

- App runs in the system tray.
- Tray menu includes: show window, run check-in now, open Linux.do login, send test email, clean temporary reports, quit.
- Closing the window should hide to tray by default.
- Quitting should ask for confirmation if a check-in is running.

### Visual Direction

- Warm white background, mist gray panels, sage green success state, coral attention state, ink text.
- Cat elements should feel like a calm assistant, not a childish mascot overload.
- Use SVG or PNG assets for the cat mascot and tray icon.
- Avoid emoji-dependent UI for important symbols because font fallback can render badly.
- Avoid one-color beige/brown themes and purple-blue AI gradients.

## 6. Functional Requirements

### Configuration

- Read `config/checkin-sites.json`.
- Read and write `config/tray-settings.json`.
- Preserve unknown fields in settings when saving.
- Validate daily run time as `HH:mm`.
- Validate site settings against configured site names.

### Check-in Execution

- `Run now` calls:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-agent-checkin.ps1
```

- The app must stream or collect stdout/stderr for display.
- The app must prevent duplicate concurrent check-in runs.
- The app must expose a `Keep reports` option.
- The app must show success, failure, network error, manual reminder, and unknown states.

### Reports

- Read newest `reports/<timestamp>/result.json` when reports exist.
- If reports are cleaned by the runner, show the summary returned by `run-agent-checkin.ps1`.
- Do not require reports to remain on disk for normal operation.

### Email

- Show whether these environment variables are configured:
  - `CHECKIN_MAIL_TO`
  - `CHECKIN_SMTP_HOST`
  - `CHECKIN_SMTP_PORT`
  - `CHECKIN_SMTP_USER`
  - `CHECKIN_SMTP_PASS`
  - `CHECKIN_MAIL_FROM`
  - `CHECKIN_SMTP_PROXY`
- Never display the value of `CHECKIN_SMTP_PASS`.
- Test email should call the existing email path first.

### Startup

- Windows startup should be user-scoped only.
- Milestone 1 uses a current-user Startup folder shortcut for startup behavior.
- Installer-integrated startup behavior is out of scope for Milestone 1.

## 7. Technical Constraints

- Primary target OS: Windows.
- The first app version must not require rewriting the working automation scripts.
- Network access remains controlled by the existing scripts and user environment.
- Milestone 1 requires `bb-browser.cmd` to be discoverable on PATH. A UI setting for the executable path is out of scope until Milestone 2.
- Local config files are the source of truth for the first milestone.
- The app should work without GitHub, Gmail connector, or Codex-specific tooling.
- The build should avoid requiring administrator privileges for normal use.

## 8. Security Constraints

- No SMTP passwords in repo files.
- No OAuth tokens in repo files.
- No hidden upload of reports or screenshots.
- Shell command invocation must use explicit allowlisted commands and arguments.
- The frontend must not be able to run arbitrary shell commands.
- Logs should redact obvious password/token-like values.

## 9. Module Boundaries

### `apps/desktop/src`

Owns UI state, rendering, user interactions, and presentation.

### `apps/desktop/src-tauri`

Owns native window, tray, filesystem access, command invocation, and OS integration.

### `packages/core`

Owns shared TypeScript types and pure logic:

- parse settings
- validate settings
- parse check-in result JSON
- map statuses to UI states

### `scripts`

Legacy engine. It owns browser automation and email sending through Milestone 1 and Milestone 2.

## 10. Migration Plan

### Milestone 1: Modern Shell

- Scaffold Tauri + React + TypeScript app.
- Implement main window matching the design direction.
- Read config and settings.
- Run existing check-in script.
- Show current and latest status.
- Implement tray menu.
- Keep existing PowerShell tray launcher as legacy fallback.

### Milestone 2: Better Runtime Integration

- Add structured command output contract from `run-agent-checkin.ps1`.
- Improve report parsing and in-app logs.
- Add app icon and cat mascot assets.
- Add build scripts and release packaging.

### Milestone 3: Engine Modernization

- Move config parsing and report logic to `packages/core`.
- Gradually replace PowerShell-only orchestration with a typed runner.
- Keep `daily-checkin.ps1` only where direct browser automation still requires it.

## 11. Testing Requirements

- Unit tests for settings parsing and result parsing.
- UI tests for key screens and state mapping.
- Command bridge tests with a fake runner script.
- Guard test to ensure legacy secrets are not written to config.
- Build verification for the desktop app.
- Existing tests must continue to pass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-checkin-config.ps1
python .\scripts\test_reminder_email.py
```

## 12. Acceptance Criteria

The first modern app milestone is acceptable when:

- The app opens as a real desktop window with crisp text on high-DPI Windows displays.
- The visual design is recognizably aligned with the cat-themed design direction.
- The tray icon and tray menu work.
- The app can read and update schedule and per-site settings.
- The app can run the existing check-in command.
- The app prevents duplicate runs.
- The app can show latest statuses and manual reminder sites.
- No secrets are written to repo files.
- The legacy PowerShell scripts still pass their guard tests.

## 13. Initial Decisions

- Use `npm` for the first desktop app scaffold unless the existing environment proves it cannot install Tauri dependencies reliably.
- Keep settings under `config/` for Milestone 1 to preserve compatibility with existing scripts.
- Target a portable Windows build first; installer packaging is a Milestone 2 task.
- Keep the check-in engine script-based through Milestone 2. Rewriting the engine is a separate Milestone 3 design.

## 14. Decisions That Require User Approval Later

- Whether to migrate runtime settings from `config/` into the OS app data directory.
- Whether to package as MSI/MSIX in addition to a portable build.
- Whether to rewrite the check-in engine in TypeScript, Rust, or keep it script-based long term.
- Whether to add a configurable `bb-browser` executable path in the UI.
