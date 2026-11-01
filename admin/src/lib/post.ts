/** 接口返回的失败：错误码由界面翻译，detail 是技术细节（可能没有） */
export class ApiError extends Error {
  constructor(
    readonly code: string,
    readonly detail?: string
  ) {
    super(code)
  }
}

/** 调 /api/passkey/* 这类返回 { ok, code, data } 的接口；失败时抛出 ApiError */
export async function post<T = unknown>(url: string, body: unknown): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const json = (await res.json().catch(() => null)) as
    | { ok: boolean; code?: string; detail?: string; data?: unknown }
    | null
  if (!json?.ok) throw new ApiError(json?.code ?? 'http', json?.detail ?? String(res.status))
  return json.data as T
}
