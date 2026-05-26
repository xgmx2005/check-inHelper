use serde::{Deserialize, Serialize};
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    thread,
    time::{Duration, Instant},
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager, WindowEvent,
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

#[derive(Debug, Serialize)]
struct CleanupResult {
    removed_directories: usize,
    removed_files: usize,
}

#[derive(Debug, Deserialize)]
struct SaveSettingsRequest {
    content: String,
}

fn repo_root() -> Result<PathBuf, String> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .map(normalize_windows_verbatim_path)
        .map_err(|error| format!("Could not resolve repository root: {error}"))
}

fn normalize_windows_verbatim_path(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(stripped) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{stripped}"));
    }
    if let Some(stripped) = text.strip_prefix(r"\\?\") {
        return PathBuf::from(stripped);
    }
    path
}

fn read_repo_file(relative_path: &str) -> Result<String, String> {
    let path = repo_root()?.join(relative_path);
    fs::read_to_string(&path).map_err(|error| format!("Could not read {}: {error}", path.display()))
}

fn command_result(output: Output) -> CommandResult {
    CommandResult {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    }
}

fn run_command_with_timeout(mut command: Command, timeout: Duration) -> Result<CommandResult, String> {
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start command: {error}"))?;
    let start = Instant::now();

    loop {
        if let Some(_status) = child
            .try_wait()
            .map_err(|error| format!("Could not poll command: {error}"))?
        {
            let output = child
                .wait_with_output()
                .map_err(|error| format!("Could not collect command output: {error}"))?;
            return Ok(command_result(output));
        }

        if start.elapsed() >= timeout {
            let _ = child.kill();
            let output = child
                .wait_with_output()
                .map_err(|error| format!("Command timed out and output could not be collected: {error}"))?;
            let mut result = command_result(output);
            result.exit_code = 124;
            if result.stderr.trim().is_empty() {
                result.stderr = format!("Command timed out after {} seconds.", timeout.as_secs());
            } else {
                result.stderr = format!(
                    "{}\nCommand timed out after {} seconds.",
                    result.stderr.trim_end(),
                    timeout.as_secs()
                );
            }
            return Ok(result);
        }

        thread::sleep(Duration::from_millis(250));
    }
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
        .arg(script)
        .arg("-NoEmail");

    if keep_reports {
        command.arg("-KeepReports");
    }

    run_command_with_timeout(command, Duration::from_secs(600))
}

#[tauri::command]
fn open_linuxdo_login() -> Result<CommandResult, String> {
    let root = repo_root()?;
    let mut command = Command::new("bb-browser.cmd");
    command.current_dir(&root).arg("open").arg("https://linux.do/");
    run_command_with_timeout(command, Duration::from_secs(45))
}

#[tauri::command]
fn send_test_email() -> Result<CommandResult, String> {
    let root = repo_root()?;
    let test_root = root.join("reports").join("tauri-email-test");
    fs::create_dir_all(&test_root).map_err(|error| format!("Could not create test report dir: {error}"))?;
    let result_json = test_root.join("result.json");
    let result_markdown = test_root.join("result.md");
    let payload = r#"[
  {
    "name": "linux.do",
    "url": "https://linux.do/",
    "status": "ok",
    "reason": "Tauri test message.",
    "finalUrl": "https://linux.do/",
    "title": "",
    "screenshot": "",
    "timestamp": ""
  },
  {
    "name": "muyuan",
    "url": "https://muyuan.do",
    "status": "manual_reminder",
    "reason": "Tauri test manual reminder.",
    "finalUrl": "https://muyuan.do",
    "title": "",
    "screenshot": "",
    "timestamp": ""
  }
]"#;

    fs::write(&result_json, payload).map_err(|error| format!("Could not write test result JSON: {error}"))?;
    fs::write(&result_markdown, "# Tauri test email\n")
        .map_err(|error| format!("Could not write test result markdown: {error}"))?;

    let mut command = Command::new("python");
    command
        .current_dir(&root)
        .arg(root.join("scripts/send_reminder_email.py"))
        .arg("--result-json")
        .arg(&result_json);

    let result = run_command_with_timeout(command, Duration::from_secs(90));
    let _ = fs::remove_dir_all(&test_root);
    result
}

#[tauri::command]
fn clean_reports() -> Result<CleanupResult, String> {
    let root = repo_root()?;
    let reports = root.join("reports");
    if !reports.exists() {
        return Ok(CleanupResult {
            removed_directories: 0,
            removed_files: 0,
        });
    }

    let reports = reports
        .canonicalize()
        .map(normalize_windows_verbatim_path)
        .map_err(|error| format!("Could not resolve reports dir: {error}"))?;
    if !reports.starts_with(&root) {
        return Err(format!("Refusing to clean reports outside repository: {}", reports.display()));
    }

    let mut removed_directories = 0;
    let mut removed_files = 0;
    for entry in fs::read_dir(&reports).map_err(|error| format!("Could not read reports dir: {error}"))? {
        let entry = entry.map_err(|error| format!("Could not read report entry: {error}"))?;
        let path = entry.path();
        if path.is_dir() {
            fs::remove_dir_all(&path).map_err(|error| format!("Could not remove {}: {error}", path.display()))?;
            removed_directories += 1;
        } else if path.is_file() {
            fs::remove_file(&path).map_err(|error| format!("Could not remove {}: {error}", path.display()))?;
            removed_files += 1;
        }
    }

    Ok(CleanupResult {
        removed_directories,
        removed_files,
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
            run_checkin,
            open_linuxdo_login,
            send_test_email,
            clean_reports
        ])
        .setup(|app| {
            build_tray(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Check-in Helper");
}

#[cfg(test)]
mod tests {
    use super::normalize_windows_verbatim_path;
    use std::path::PathBuf;

    #[test]
    fn strips_windows_verbatim_disk_prefix() {
        assert_eq!(
            normalize_windows_verbatim_path(PathBuf::from(r"\\?\G:\CODE\checkinHelper")),
            PathBuf::from(r"G:\CODE\checkinHelper")
        );
    }

    #[test]
    fn strips_windows_verbatim_unc_prefix() {
        assert_eq!(
            normalize_windows_verbatim_path(PathBuf::from(r"\\?\UNC\server\share\repo")),
            PathBuf::from(r"\\server\share\repo")
        );
    }
}
