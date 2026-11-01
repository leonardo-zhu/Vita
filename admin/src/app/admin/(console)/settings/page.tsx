import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatTime } from '@/lib/format'
import { publishDir } from '@/server/config/publisher'
import { listPasskeys } from '@/server/db'

import { PasskeyManager } from './passkey-manager'

export const metadata = { title: '设置 · Vita Admin' }

export default async function SettingsPage() {
  const passkeys = listPasskeys().map((row) => ({
    id: row.id,
    name: row.name,
    createdAt: formatTime(row.created_at),
    lastUsedAt: formatTime(row.last_used_at),
  }))
  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold">设置</h1>
      <Card>
        <CardHeader>
          <CardTitle>Passkey</CardTitle>
          <CardDescription>注册后可以不输密码登录。添加前需要再确认一次密码。</CardDescription>
        </CardHeader>
        <CardContent>
          <PasskeyManager passkeys={passkeys} />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>发布</CardTitle>
          <CardDescription>发布的文件由 Caddy 直接提供，不经过 Admin。</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 text-sm">
          <Row label="对外地址" value="https://vita.r4s.leonardo-zhu.me/config/stable.json" />
          <Row label="发布目录" value={publishDir()} />
          <Row
            label="模型别名检查"
            value={
              process.env.CONDUIT_BASE_URL && process.env.CONDUIT_API_KEY
                ? `已启用（${process.env.CONDUIT_BASE_URL}）`
                : '未配置 CONDUIT_BASE_URL / CONDUIT_API_KEY，发布时不检查'
            }
          />
        </CardContent>
      </Card>
    </div>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:gap-4">
      <span className="w-28 shrink-0 text-muted-foreground">{label}</span>
      <span className="font-mono text-xs break-all sm:text-sm">{value}</span>
    </div>
  )
}
