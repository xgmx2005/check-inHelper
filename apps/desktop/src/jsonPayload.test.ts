import { describe, expect, it } from "vitest";
import { parseTauriJsonPayload } from "./jsonPayload";

describe("parseTauriJsonPayload", () => {
  it("parses JSON strings returned by Tauri commands", () => {
    expect(parseTauriJsonPayload('{"dailyRunTime":"10:00"}', { dailyRunTime: "09:00" })).toEqual({
      dailyRunTime: "10:00",
    });
  });

  it("accepts already parsed objects", () => {
    expect(parseTauriJsonPayload({ dailyRunTime: "11:00" }, { dailyRunTime: "09:00" })).toEqual({
      dailyRunTime: "11:00",
    });
  });

  it("strips UTF-8 BOM before parsing", () => {
    expect(parseTauriJsonPayload('\uFEFF{"ok":true}', { ok: false })).toEqual({ ok: true });
  });

  it("returns fallback for empty payloads", () => {
    expect(parseTauriJsonPayload("", { ok: false })).toEqual({ ok: false });
  });
});
