import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useEffect, useMemo, useState } from "react";
import { buildSiteRows, countConfiguredSmtpVars, countEnabledSites, countManualSites } from "./viewModel";
import type { CheckinConfig, CommandResult, SmtpVarStatus, TraySettings } from "./viewTypes";

const emptyConfig: CheckinConfig = {
  linuxDo: { url: "https://linux.do/" },
  defaults: {},
  sites: [],
};

const emptySettings: TraySettings = {
  dailyRunTime: "10:00",
  startWithWindows: false,
  keepReports: false,
  sites: {},
};

type RunState = "idle" | "running" | "success" | "failed";

function CatMark() {
  return (
    <div className="cat-mark" aria-hidden="true">
      <span className="cat-ear left" />
      <span className="cat-ear right" />
      <span className="cat-face">
        <span className="cat-eye left" />
        <span className="cat-eye right" />
        <span className="cat-mouth" />
      </span>
    </div>
  );
}

function App() {
  const [config, setConfig] = useState<CheckinConfig>(emptyConfig);
  const [settings, setSettings] = useState<TraySettings>(emptySettings);
  const [smtpStatus, setSmtpStatus] = useState<SmtpVarStatus[]>([]);
  const [runState, setRunState] = useState<RunState>("idle");
  const [log, setLog] = useState("等待小猫助手巡查。");
  const [error, setError] = useState("");

  async function loadInitialState() {
    try {
      const [configText, settingsText, smtp] = await Promise.all([
        invoke<string>("load_config"),
        invoke<string>("load_settings"),
        invoke<SmtpVarStatus[]>("get_smtp_status"),
      ]);
      setConfig(JSON.parse(configText));
      setSettings(JSON.parse(settingsText));
      setSmtpStatus(smtp);
      setError("");
    } catch (reason) {
      setError(String(reason));
    }
  }

  async function runNow() {
    if (runState === "running") return;
    setRunState("running");
    setLog("正在调用 legacy check-in engine...");
    setError("");
    try {
      const result = await invoke<CommandResult>("run_checkin", {
        keepReports: settings.keepReports,
      });
      setRunState(result.exit_code === 0 ? "success" : "failed");
      setLog([result.stdout, result.stderr].filter(Boolean).join("\n\n") || `Exit code: ${result.exit_code}`);
    } catch (reason) {
      setRunState("failed");
      setError(String(reason));
    }
  }

  useEffect(() => {
    void loadInitialState();
    const unlisten = listen("checkin://run-requested", () => {
      void runNow();
    });
    return () => {
      void unlisten.then((dispose) => dispose());
    };
  }, []);

  const rows = useMemo(() => buildSiteRows(config, settings), [config, settings]);
  const enabledCount = countEnabledSites(settings);
  const manualCount = countManualSites(settings);
  const smtpReady = countConfiguredSmtpVars(smtpStatus);

  async function persistSettings(nextSettings: TraySettings) {
    setSettings(nextSettings);
    await invoke("save_settings", {
      request: {
        content: JSON.stringify(nextSettings, null, 2),
      },
    });
  }

  async function updateSite(name: string, patch: Partial<{ enabled: boolean; manualReminderOnly: boolean }>) {
    const current = settings.sites[name] ?? { enabled: true, manualReminderOnly: false };
    await persistSettings({
      ...settings,
      sites: {
        ...settings.sites,
        [name]: {
          ...current,
          ...patch,
        },
      },
    });
  }

  async function updateSchedule(value: string) {
    await persistSettings({
      ...settings,
      dailyRunTime: value,
    });
  }

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand-row">
          <CatMark />
          <div>
            <div className="brand-title">Check-in Helper</div>
            <div className="brand-subtitle">Linux.do OAuth daily assistant</div>
          </div>
        </div>

        <nav className="nav-list">
          <button className="nav-item active">今日签到</button>
          <button className="nav-item">站点状态</button>
          <button className="nav-item">邮件提醒</button>
          <button className="nav-item">清理策略</button>
        </nav>

        <section className="cat-note">
          <div className="note-title">小猫助手</div>
          <p>定时巡查、失败提醒、手动站点轻轻拍你一下。</p>
        </section>

        <div className="doctor-pill">
          <span>Doctor</span>
          <strong>{runState === "running" ? "Running" : "Waiting"}</strong>
        </div>
      </aside>

      <section className="content">
        <header className="hero">
          <div>
            <p className="eyebrow">Modern desktop shell</p>
            <h1>今日签到</h1>
            <p className="hero-copy">当前状态：{runState} · 下一次按计划运行：{settings.dailyRunTime}</p>
          </div>
          <div className="assistant-card">
            <CatMark />
            <span>小猫助手在线</span>
          </div>
        </header>

        {error ? <div className="error-banner">{error}</div> : null}

        <section className="summary-grid">
          <article className="summary-card">
            <span>站点状态</span>
            <strong>{enabledCount} 个启用</strong>
          </article>
          <article className="summary-card attention">
            <span>手动提醒</span>
            <strong>{manualCount} 个需要处理</strong>
          </article>
          <article className="summary-card">
            <span>邮件提醒</span>
            <strong>{smtpReady}/{smtpStatus.length || 7} configured</strong>
          </article>
          <article className="summary-card">
            <span>计划任务</span>
            <strong>{settings.dailyRunTime}</strong>
          </article>
        </section>

        <section className="panel schedule-panel">
          <div>
            <h2>计划任务</h2>
            <p>托盘启动后，小猫助手会在这个时间巡查一次。</p>
            <div className="yarn-line"><span /> 今日状态已汇总</div>
          </div>
          <div className="schedule-actions">
            <input
              aria-label="每日运行时间"
              type="time"
              value={settings.dailyRunTime}
              onChange={(event) => void updateSchedule(event.target.value)}
            />
            <label>
              <input
                type="checkbox"
                checked={settings.startWithWindows}
                onChange={(event) => void persistSettings({ ...settings, startWithWindows: event.target.checked })}
              />
              开机自启动
            </label>
            <label>
              <input
                type="checkbox"
                checked={settings.keepReports}
                onChange={(event) => void persistSettings({ ...settings, keepReports: event.target.checked })}
              />
              调试时保留本地报告
            </label>
            <button className="primary-button" disabled={runState === "running"} onClick={() => void runNow()}>
              {runState === "running" ? "运行中" : "立即签到"}
            </button>
          </div>
        </section>

        <section className="panel">
          <div className="section-title">
            <h2>站点状态</h2>
            <span>来自 config/checkin-sites.json</span>
          </div>
          <div className="site-table">
            <div className="site-row header">
              <span>站点</span>
              <span>今日状态</span>
              <span>启用</span>
              <span>手动提醒</span>
              <span>地址</span>
            </div>
            {rows.map((row) => (
              <div className="site-row" key={row.name}>
                <strong>{row.name}</strong>
                <span className={row.manualReminderOnly ? "status attention" : "status ok"}>{row.uiStatus}</span>
                <label>
                  <input
                    type="checkbox"
                    checked={row.enabled}
                    onChange={(event) => void updateSite(row.name, { enabled: event.target.checked })}
                  />
                </label>
                <label>
                  <input
                    type="checkbox"
                    checked={row.manualReminderOnly}
                    onChange={(event) => void updateSite(row.name, { manualReminderOnly: event.target.checked })}
                  />
                </label>
                <span className="url-cell">{row.url}</span>
              </div>
            ))}
          </div>
        </section>

        <section className="log-panel">
          <h2>运行日志</h2>
          <pre>{log}</pre>
        </section>
      </section>
    </main>
  );
}

export default App;
