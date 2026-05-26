export type CheckinStatus =
  | "ok"
  | "success"
  | "already_done"
  | "manual_reminder"
  | "dry_run"
  | "failed"
  | "unknown"
  | "network_error";

export type SiteConfig = {
  name: string;
  url: string;
  manualReminderOnly?: boolean;
  emailOnFailure?: boolean;
};

export type CheckinConfig = {
  linuxDo: {
    url: string;
  };
  defaults: Record<string, unknown>;
  sites: SiteConfig[];
};

export type SiteSettings = {
  enabled: boolean;
  manualReminderOnly: boolean;
};

export type TraySettings = {
  dailyRunTime: string;
  startWithWindows: boolean;
  keepReports: boolean;
  lastScheduledRunDate?: string;
  sites: Record<string, SiteSettings>;
};

export type CheckinResult = {
  name: string;
  url: string;
  status: CheckinStatus;
  reason: string;
  finalUrl?: string;
  title?: string;
  screenshot?: string;
  timestamp?: string;
};

export type UiTone = "ok" | "attention" | "muted" | "running";

export type UiStatus = {
  label: string;
  tone: UiTone;
};
