import type { CheckinResult } from "./checkinTypes";

export function parseCheckinResults(value: unknown): CheckinResult[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .filter((item) => item && typeof item === "object")
    .map((item) => item as Partial<CheckinResult>)
    .filter((item) => typeof item.name === "string" && typeof item.status === "string")
    .map((item) => ({
      name: item.name ?? "",
      url: item.url ?? "",
      status: item.status as CheckinResult["status"],
      reason: item.reason ?? "",
      finalUrl: item.finalUrl ?? item.url ?? "",
      title: item.title ?? "",
      screenshot: item.screenshot ?? "",
      timestamp: item.timestamp ?? "",
    }));
}
