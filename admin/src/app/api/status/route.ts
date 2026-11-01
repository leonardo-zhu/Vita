// 容器健康检查用，不需要登录
export function GET() {
  return Response.json({ success: true })
}
