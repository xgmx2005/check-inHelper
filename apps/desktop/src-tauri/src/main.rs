use serde::{Deserialize, Serialize};
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};

#[derive(Debug, Serialize)]
struct SmtpVarStatus {
    name: String,
    configured: bool,
    secret: bool,
}

#[derive(Debug, Serialize)]
struct CommandResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

#[derive(Debug, Deserialize)]
struct SaveSettingsRequest {
    content: String,
}

fn repo_root() -> Result<PathBuf, String> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .map_err(|error| format!("Could not resolve repository root: {error}"))
}

fn read_repo_file(relative_path: &str) -> Result<String, String> {
    let path = repo_root()?.join(relative_path);
    fs::read_to_string(&path).map_err(|error| format!("Could not read {}: {error}", path.display()))
}

#[tauri::command]
fn load_config() -> Result<String, String> {
    read_repo_file("config/checkin-sites.json")
}

#[tauri::command]
fn load_settings() -> Result<String, String> {
    read_repo_file("config/tray-settings.json")
}

#[tauri::command]
fn save_settings(request: SaveSettingsRequest) -> Result<(), String> {
    let path = repo_root()?.join("config/tray-settings.json");
    fs::write(&path, request.content).map_err(|error| format!("Could not save {}: {error}", path.display()))
}

#[tauri::command]
fn get_smtp_status() -> Vec<SmtpVarStatus> {
    [
        ("CHECKIN_MAIL_TO", false),
        ("CHECKIN_SMTP_HOST", false),
        ("CHECKIN_SMTP_PORT", false),
        ("CHECKIN_SMTP_USER", false),
        ("CHECKIN_SMTP_PASS", true),
        ("CHECKIN_MAIL_FROM", false),
        ("CHECKIN_SMTP_PROXY", false),
    ]
    .into_iter()
    .map(|(name, secret)| SmtpVarStatus {
        name: name.to_string(),
        configured: env::var(name).map(|value| !value.trim().is_empty()).unwrap_or(false),
        secret,
    })
    .collect()
}

#[tauri::command]
fn run_checkin(keep_reports: bool) -> Result<CommandResult, String> {
    let root = repo_root()?;
    let script = root.join("scripts/run-agent-checkin.ps1");
    let mut command = Command::new("powershell");
    command
        .current_dir(&root)
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(script);

    if keep_reports {
        command.arg("-KeepReports");
    }

    let output = command
        .output()
        .map_err(|error| format!("Could not run check-in script: {error}"))?;

    Ok(CommandResult {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    })
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Show Check-in Helper", true, None::<&str>)?;
    let run = MenuItem::with_id(app, "run", "Run check-in now", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &run, &quit])?;

    TrayIconBuilder::new()
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "run" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.emit("checkin://run-requested", ());
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Some(window) = tray.app_handle().get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    Ok(())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            load_config,
            load_settings,
            save_settings,
            get_smtp_status,
            run_checkin
        ])
        .setup(|app| {
            build_tray(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Check-in Helper");
}
