/** 调 /api/passkey/* 这类返回 { ok, message, data } 的接口；失败时抛出带服务端说明的错误 */
export async function post<T = unknown>(url: string, body: unknown): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const json = (await res.json().catch(() => null)) as { ok: boolean; message?: string; data?: unknown } | null
  if (!json?.ok) throw new Error(json?.message ?? `请求失败（${res.status}）`)
  return json.data as T
}
