# Modern App M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Tauri + React desktop shell for Check-in Helper while preserving the existing PowerShell/Python check-in engine.

**Architecture:** `apps/desktop` owns the desktop app, React UI, and Tauri native bridge. `packages/core` owns shared TypeScript parsing and status mapping for config/settings/report data. Existing `scripts/` remain the legacy engine and are invoked by Tauri commands.

**Tech Stack:** Tauri 2, React, TypeScript, Vite, Tailwind CSS, Vitest, Rust.

---

### Task 1: Workspace And Desktop Scaffold

**Files:**
- Create: `package.json`
- Create: `apps/desktop/package.json`
- Create: `apps/desktop/index.html`
- Create: `apps/desktop/src/main.tsx`
- Create: `apps/desktop/src/App.tsx`
- Create: `apps/desktop/src/styles.css`
- Create: `apps/desktop/vite.config.ts`
- Create: `apps/desktop/tsconfig.json`
- Create: `apps/desktop/src-tauri/Cargo.toml`
- Create: `apps/desktop/src-tauri/tauri.conf.json`
- Create: `apps/desktop/src-tauri/src/main.rs`

- [ ] Add npm workspace scripts for `desktop:dev`, `desktop:build`, `desktop:test`.
- [ ] Add Vite React entrypoint.
- [ ] Add Tauri Rust entrypoint with basic window configuration.
- [ ] Verify `npm install` succeeds.

### Task 2: Shared Core Package

**Files:**
- Create: `packages/core/package.json`
- Create: `packages/core/tsconfig.json`
- Create: `packages/core/src/index.ts`
- Create: `packages/core/src/checkinTypes.ts`
- Create: `packages/core/src/settingsSchema.ts`
- Create: `packages/core/src/reportParser.ts`
- Create: `packages/core/src/statusMapping.ts`
- Create: `packages/core/src/statusMapping.test.ts`

- [ ] Define config, settings, result, and UI status types.
- [ ] Implement pure parsers for site config and tray settings.
- [ ] Implement status mapping for `success`, `already_done`, `manual_reminder`, `failed`, `unknown`, and `network_error`.
- [ ] Add Vitest coverage for status mapping.

### Task 3: Tauri Bridge

**Files:**
- Modify: `apps/desktop/src-tauri/src/main.rs`

- [ ] Add allowlisted Tauri commands:
  - `load_config`
  - `load_settings`
  - `save_settings`
  - `get_smtp_status`
  - `run_checkin`
- [ ] Make commands resolve paths relative to repository root during development.
- [ ] Ensure `run_checkin` calls `scripts/run-agent-checkin.ps1` with fixed arguments only.
- [ ] Return structured command output to the frontend.

### Task 4: First Modern UI

**Files:**
- Modify: `apps/desktop/src/App.tsx`
- Modify: `apps/desktop/src/styles.css`

- [ ] Render the cat-themed dashboard shell.
- [ ] Show summary cards for site status, manual reminders, SMTP readiness, and schedule.
- [ ] Show the site table from `config/checkin-sites.json` and `config/tray-settings.json`.
- [ ] Add actions for run now, open Linux.do login placeholder, send test email placeholder, and clean reports placeholder.
- [ ] Keep layout crisp at high DPI using normal web text rendering, not emoji-dependent critical icons.

### Task 5: Verification

**Commands:**
- `npm test`
- `npm run desktop:build`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-checkin-config.ps1`
- `python .\scripts\test_reminder_email.py`

- [ ] All commands must pass before committing.
- [ ] Do not include `config/tray-settings.json` runtime changes in the commit.
