import { NextResponse, type NextRequest } from 'next/server'

import { MAX_BODY_BYTES, ingest } from '@/server/diagnostics/ingest'

// 客户端诊断日志上报（vita-admin.md §11.4）。与 /admin 的鉴权分开：不看会话 cookie，
// 只认 schema、体积上限与限流；被封禁的安装 ID 返回 403。
export async function POST(req: NextRequest) {
  const declared = Number(req.headers.get('content-length') ?? 0)
  if (declared > MAX_BODY_BYTES) return NextResponse.json({ error: 'too large' }, { status: 413 })
  const text = await req.text()
  if (Buffer.byteLength(text) > MAX_BODY_BYTES) return NextResponse.json({ error: 'too large' }, { status: 413 })

  let body: unknown
  try {
    body = JSON.parse(text)
  } catch {
    return NextResponse.json({ error: 'invalid json' }, { status: 400 })
  }
  // Caddy 反代时带 X-Forwarded-For；Next.js 只监听 127.0.0.1，可以信任
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'local'
  const result = ingest(body, ip)
  if (result.status !== 200) return NextResponse.json({ error: result.error }, { status: result.status })
  return NextResponse.json({ accepted: result.accepted, duplicates: result.duplicates, dropped: result.dropped })
}
