import type { CleanupResult, CommandResult } from "./viewTypes";

export function formatCommandResult(action: string, result: CommandResult): string {
  const chunks = [
    `${action} finished with exit code ${result.exit_code}.`,
    result.stdout.trim(),
    result.stderr.trim(),
  ].filter(Boolean);

  return chunks.join("\n\n");
}

export function formatCleanupResult(result: CleanupResult): string {
  return `Cleaned ${result.removed_directories} report director${result.removed_directories === 1 ? "y" : "ies"} and ${result.removed_files} file${result.removed_files === 1 ? "" : "s"}.`;
}
