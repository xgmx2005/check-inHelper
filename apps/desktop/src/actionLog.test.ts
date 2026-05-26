import { describe, expect, it } from "vitest";
import { formatCleanupResult, formatCommandResult } from "./actionLog";

describe("action log formatters", () => {
  it("formats command output with stdout and stderr", () => {
    expect(formatCommandResult("Run", { exit_code: 1, stdout: "out", stderr: "err" })).toBe(
      "Run finished with exit code 1.\n\nout\n\nerr",
    );
  });

  it("formats cleanup counts", () => {
    expect(formatCleanupResult({ removed_directories: 2, removed_files: 1 })).toBe(
      "Cleaned 2 report directories and 1 file.",
    );
  });
});
