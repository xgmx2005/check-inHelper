import type { CheckinStatus, UiStatus } from "./checkinTypes";

export function mapStatusToUi(status: CheckinStatus | string): UiStatus {
  switch (status) {
    case "ok":
    case "success":
    case "already_done":
      return { label: "全部正常", tone: "ok" };
    case "dry_run":
      return { label: "演练通过", tone: "muted" };
    case "manual_reminder":
      return { label: "需要处理", tone: "attention" };
    case "failed":
    case "unknown":
    case "network_error":
      return { label: "异常", tone: "attention" };
    default:
      return { label: "未运行", tone: "muted" };
  }
}

export function isAttentionStatus(status: CheckinStatus | string): boolean {
  return mapStatusToUi(status).tone === "attention";
}
