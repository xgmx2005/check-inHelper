import { describe, expect, it } from "vitest";
import { buildSiteRows, countConfiguredSmtpVars, countEnabledSites, countManualSites } from "./viewModel";
import type { CheckinConfig, TraySettings } from "./viewTypes";

const config: CheckinConfig = {
  linuxDo: { url: "https://linux.do/" },
  defaults: {},
  sites: [
    { name: "auto", url: "https://auto.example" },
    { name: "manual", url: "https://manual.example", manualReminderOnly: true },
  ],
};

const settings: TraySettings = {
  dailyRunTime: "10:00",
  startWithWindows: false,
  keepReports: false,
  sites: {
    auto: { enabled: true, manualReminderOnly: false },
    manual: { enabled: true, manualReminderOnly: true },
  },
};

describe("desktop view model", () => {
  it("counts enabled and manual reminder sites", () => {
    expect(countEnabledSites(settings)).toBe(2);
    expect(countManualSites(settings)).toBe(1);
  });

  it("builds table rows with Chinese UI statuses", () => {
    expect(buildSiteRows(config, settings).map((row) => row.uiStatus)).toEqual(["全部正常", "需要处理"]);
  });

  it("counts configured SMTP variables", () => {
    expect(
      countConfiguredSmtpVars([
        { name: "CHECKIN_MAIL_TO", configured: true, secret: false },
        { name: "CHECKIN_SMTP_PASS", configured: false, secret: true },
      ]),
    ).toBe(1);
  });
});
