/**
 * 发布前确认模型别名在 Conduit 上存在（vita-admin.md §8.3 / §11.1）。
 * 用 Conduit 给 Vita 应用建的专用 API 密钥调 /v1/models。没配置时跳过，连不上时只提示不拦截。
 */
export type AliasCheck =
  | { status: 'ok' }
  | { status: 'missing'; alias: string }
  | { status: 'skipped' }
  | { status: 'error'; detail: string }

export async function checkModelAlias(modelId: string): Promise<AliasCheck> {
  const baseUrl = process.env.CONDUIT_BASE_URL
  const apiKey = process.env.CONDUIT_API_KEY
  if (!baseUrl || !apiKey) return { status: 'skipped' }
  try {
    const res = await fetch(new URL('/v1/models', baseUrl), {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(5000),
      cache: 'no-store',
    })
    if (!res.ok) return { status: 'error', detail: `HTTP ${res.status}` }
    const body = (await res.json()) as { data?: { id?: string }[] }
    const ids = new Set((body.data ?? []).map((model) => model.id))
    return ids.has(modelId) ? { status: 'ok' } : { status: 'missing', alias: modelId }
  } catch (error) {
    return { status: 'error', detail: (error as Error).message }
  }
}
