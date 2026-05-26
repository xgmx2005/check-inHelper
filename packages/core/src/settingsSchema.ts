import type { CheckinConfig, TraySettings } from "./checkinTypes";

const timePattern = /^\d{2}:\d{2}$/;

export function parseCheckinConfig(value: unknown): CheckinConfig {
  const config = value as Partial<CheckinConfig>;
  if (!config || typeof config !== "object" || !Array.isArray(config.sites)) {
    throw new Error("Invalid check-in config: missing sites.");
  }

  return config as CheckinConfig;
}

export function parseTraySettings(value: unknown, config: CheckinConfig): TraySettings {
  const settings = value as Partial<TraySettings>;
  const dailyRunTime = typeof settings.dailyRunTime === "string" && timePattern.test(settings.dailyRunTime)
    ? settings.dailyRunTime
    : "10:00";

  const sourceSites = settings.sites && typeof settings.sites === "object" ? settings.sites : {};
  const sites: TraySettings["sites"] = {};
  for (const site of config.sites) {
    const saved = sourceSites[site.name];
    sites[site.name] = {
      enabled: saved?.enabled ?? true,
      manualReminderOnly: saved?.manualReminderOnly ?? Boolean(site.manualReminderOnly),
    };
  }

  return {
    dailyRunTime,
    startWithWindows: Boolean(settings.startWithWindows),
    keepReports: Boolean(settings.keepReports),
    lastScheduledRunDate: settings.lastScheduledRunDate ?? "",
    sites,
  };
}
