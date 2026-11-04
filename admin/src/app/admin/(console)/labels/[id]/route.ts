import { requireSession } from '@/server/auth'
import { labelImage } from '@/server/vita-api'

/** 标签照片：登录后才能看，经服务令牌从 Vita API 取。 */
export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  await requireSession()
  const { id } = await params
  if (!/^[0-9a-f-]{36}$/i.test(id)) return new Response(null, { status: 404 })
  const image = await labelImage(id)
  if (!image) return new Response(null, { status: 404 })
  return new Response(image.bytes, { headers: { 'content-type': image.contentType, 'cache-control': 'private, max-age=86400' } })
}
