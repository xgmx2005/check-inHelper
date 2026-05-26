export function parseTauriJsonPayload<T>(payload: unknown, fallback: T): T {
  if (payload === null || payload === undefined || payload === "") {
    return fallback;
  }

  if (typeof payload !== "string") {
    return payload as T;
  }

  const cleaned = payload.replace(/^\uFEFF/, "").trim();
  if (!cleaned) {
    return fallback;
  }

  return JSON.parse(cleaned) as T;
}
