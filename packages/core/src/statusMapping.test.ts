import { describe, expect, it } from "vitest";
import { isAttentionStatus, mapStatusToUi } from "./statusMapping";

describe("status mapping", () => {
  it("maps successful statuses to healthy UI state", () => {
    expect(mapStatusToUi("success")).toEqual({ label: "全部正常", tone: "ok" });
    expect(mapStatusToUi("already_done")).toEqual({ label: "全部正常", tone: "ok" });
  });

  it("maps manual reminders and failures to attention UI state", () => {
    expect(mapStatusToUi("manual_reminder")).toEqual({ label: "需要处理", tone: "attention" });
    expect(isAttentionStatus("failed")).toBe(true);
    expect(isAttentionStatus("network_error")).toBe(true);
  });

  it("maps unknown future statuses to a muted state", () => {
    expect(mapStatusToUi("not_seen_before")).toEqual({ label: "未运行", tone: "muted" });
  });
});
