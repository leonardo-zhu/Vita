import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { googleHealthStatus, vitaApiConfigured } from '@/server/vita-api'

import { GoogleHealthPanel } from './google-health-panel'

export const generateMetadata = titled('googleHealth')

const seconds = (iso: string | null) => (iso ? Math.floor(Date.parse(iso) / 1000) : null)

/** Google 授权完成后，API 把浏览器跳回这里，带 ?result=connected|failed。 */
export default async function GoogleHealthPage({ searchParams }: { searchParams: Promise<{ result?: string }> }) {
  const t = await getT()
  const { result } = await searchParams
  if (!vitaApiConfigured()) {
    return (
      <div className="flex flex-col gap-6">
        <h1 className="text-xl font-semibold">{t.googleHealth.title}</h1>
        <Alert>
          <AlertTitle>{t.devices.notConfiguredTitle}</AlertTitle>
          <AlertDescription>{t.devices.notConfiguredBody}</AlertDescription>
        </Alert>
      </div>
    )
  }

  let status: Awaited<ReturnType<typeof googleHealthStatus>> | null = null
  let loadError: string | null = null
  try {
    status = await googleHealthStatus()
  } catch (error) {
    loadError = (error as Error).message
  }

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold">{t.googleHealth.title}</h1>
      {result === 'connected' && (
        <Alert>
          <AlertDescription>{t.googleHealth.resultConnected}</AlertDescription>
        </Alert>
      )}
      {result === 'failed' && (
        <Alert variant="destructive">
          <AlertDescription>{t.googleHealth.resultFailed}</AlertDescription>
        </Alert>
      )}
      <Card>
        <CardHeader>
          <CardTitle>{t.googleHealth.title}</CardTitle>
          <CardDescription>{t.googleHealth.description}</CardDescription>
        </CardHeader>
        <CardContent>
          {loadError ? (
            <p className="text-sm text-destructive">{t.googleHealth.loadFailed(loadError)}</p>
          ) : status && !status.configured ? (
            <Alert>
              <AlertTitle>{t.googleHealth.notConfiguredTitle}</AlertTitle>
              <AlertDescription>{t.googleHealth.notConfiguredBody}</AlertDescription>
            </Alert>
          ) : status ? (
            <GoogleHealthPanel
              connected={status.connected}
              connectedAt={status.connectedAt ? formatTime(seconds(status.connectedAt)) : null}
              lastSyncAt={status.lastSyncAt ? formatTime(seconds(status.lastSyncAt)) : null}
              lastError={status.lastError}
              lastErrorAt={status.lastErrorAt ? formatTime(seconds(status.lastErrorAt)) : null}
            />
          ) : null}
        </CardContent>
      </Card>
    </div>
  )
}
