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

export type SmtpVarStatus = {
  name: string;
  configured: boolean;
  secret: boolean;
};

export type CommandResult = {
  exit_code: number;
  stdout: string;
  stderr: string;
};

export type CleanupResult = {
  removed_directories: number;
  removed_files: number;
};
