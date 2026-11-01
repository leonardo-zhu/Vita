import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { publishDir } from '@/server/config/publisher'
import { listPasskeys } from '@/server/db'

import { PasskeyManager } from './passkey-manager'

export const generateMetadata = titled('settings')

export default async function SettingsPage() {
  const t = await getT()
  const passkeys = listPasskeys().map((row) => ({
    id: row.id,
    name: row.name,
    createdAt: formatTime(row.created_at),
    lastUsedAt: formatTime(row.last_used_at),
  }))
  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold">{t.settings.title}</h1>
      <Card>
        <CardHeader>
          <CardTitle>{t.settings.passkeyTitle}</CardTitle>
          <CardDescription>{t.settings.passkeyDescription}</CardDescription>
        </CardHeader>
        <CardContent>
          <PasskeyManager passkeys={passkeys} />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>{t.settings.publishTitle}</CardTitle>
          <CardDescription>{t.settings.publishDescription}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 text-sm">
          <Row label={t.settings.publicUrl} value="https://vita.r4s.leonardo-zhu.me/config/stable.json" />
          <Row label={t.settings.publishDir} value={publishDir()} />
          <Row
            label={t.settings.conduit}
            value={
              process.env.CONDUIT_BASE_URL && process.env.CONDUIT_API_KEY
                ? t.settings.conduitOn(process.env.CONDUIT_BASE_URL)
                : t.settings.conduitOff
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
