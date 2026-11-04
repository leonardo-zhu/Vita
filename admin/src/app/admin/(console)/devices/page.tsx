import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { titled } from '@/i18n/metadata'
import { getT } from '@/i18n/server'
import { formatTime } from '@/lib/format'
import { listDevices, vitaApiConfigured } from '@/server/vita-api'

import { DeviceManager } from './device-manager'

export const generateMetadata = titled('devices')

/** 手机的公网地址，签发令牌时一起展示，方便填到手机上。 */
const PUBLIC_API_URL = process.env.VITA_API_PUBLIC_URL ?? 'https://vita-api.r4s.leonardo-zhu.me'

const seconds = (iso: string | null) => (iso ? Math.floor(Date.parse(iso) / 1000) : null)

export default async function DevicesPage() {
  const t = await getT()
  if (!vitaApiConfigured()) {
    return (
      <div className="flex flex-col gap-6">
        <h1 className="text-xl font-semibold">{t.devices.title}</h1>
        <Alert>
          <AlertTitle>{t.devices.notConfiguredTitle}</AlertTitle>
          <AlertDescription>{t.devices.notConfiguredBody}</AlertDescription>
        </Alert>
      </div>
    )
  }

  let devices: Awaited<ReturnType<typeof listDevices>> = []
  let loadError: string | null = null
  try {
    devices = await listDevices()
  } catch (error) {
    loadError = (error as Error).message
  }

  return (
    <div className="flex flex-col gap-6">
      <h1 className="text-xl font-semibold">{t.devices.title}</h1>
      <Card>
        <CardHeader>
          <CardTitle>{t.devices.title}</CardTitle>
          <CardDescription>{t.devices.description}</CardDescription>
        </CardHeader>
        <CardContent>
          {loadError ? (
            <p className="text-sm text-destructive">{t.devices.loadFailed(loadError)}</p>
          ) : (
            <DeviceManager
              serverUrl={PUBLIC_API_URL}
              devices={devices.map((device) => ({
                id: device.id,
                name: device.name,
                createdAt: formatTime(seconds(device.createdAt)),
                lastUsedAt: device.lastUsedAt ? formatTime(seconds(device.lastUsedAt)) : null,
                revokedAt: device.revokedAt ? formatTime(seconds(device.revokedAt)) : null,
              }))}
            />
          )}
        </CardContent>
      </Card>
    </div>
  )
}
