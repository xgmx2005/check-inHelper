import type { CheckinConfig, SmtpVarStatus, TraySettings } from "./viewTypes";

export function countEnabledSites(settings: TraySettings): number {
  return Object.values(settings.sites).filter((site) => site.enabled).length;
}

export function countManualSites(settings: TraySettings): number {
  return Object.values(settings.sites).filter((site) => site.enabled && site.manualReminderOnly).length;
}

export function countConfiguredSmtpVars(items: SmtpVarStatus[]): number {
  return items.filter((item) => item.configured).length;
}

export function buildSiteRows(config: CheckinConfig, settings: TraySettings) {
  return config.sites.map((site) => {
    const saved = settings.sites[site.name] ?? {
      enabled: true,
      manualReminderOnly: Boolean(site.manualReminderOnly),
    };

    return {
      ...site,
      enabled: saved.enabled,
      manualReminderOnly: saved.manualReminderOnly,
      uiStatus: saved.manualReminderOnly ? "需要处理" : "全部正常",
    };
  });
}
