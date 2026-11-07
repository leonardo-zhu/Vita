'use client'

import { useTransition } from 'react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useT } from '@/i18n/client'

import { disconnectGoogleHealthAction, startGoogleHealthAction, syncGoogleHealthAction } from '../../actions'

interface Props {
  connected: boolean
  connectedAt: string | null
  lastSyncAt: string | null
  lastError: string | null
  lastErrorAt: string | null
}

export function GoogleHealthPanel({ connected, connectedAt, lastSyncAt, lastError, lastErrorAt }: Props) {
  const t = useT()
  const [pending, startTransition] = useTransition()
  const needsReconnect = lastError === 'reauthorizationRequired'

  function connect() {
    startTransition(async () => {
      const result = await startGoogleHealthAction()
      if (!result.ok) {
        toast.error(result.message)
        return
      }
      // 整页跳到 Google；授权完 API 会跳回 /admin/google-health
      window.location.assign(result.url)
    })
  }

  function sync() {
    startTransition(async () => {
      const result = await syncGoogleHealthAction()
      if (result.ok) toast.success(result.message)
      else toast.error(result.message)
    })
  }

  function disconnect() {
    if (!window.confirm(t.googleHealth.disconnectConfirm)) return
    startTransition(async () => {
      const result = await disconnectGoogleHealthAction()
      if (result.ok) toast.success(result.message)
      else toast.error(result.message)
    })
  }

  return (
    <div className="flex flex-col gap-4 text-sm">
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2">
        <dt className="text-muted-foreground">{t.googleHealth.status}</dt>
        <dd>
          <Badge variant={connected ? 'default' : 'secondary'}>{connected ? t.googleHealth.connected : t.googleHealth.notConnected}</Badge>
        </dd>
        {connected && (
          <>
            <dt className="text-muted-foreground">{t.googleHealth.connectedAt}</dt>
            <dd>{connectedAt ?? '—'}</dd>
            <dt className="text-muted-foreground">{t.googleHealth.lastSync}</dt>
            <dd>{lastSyncAt ?? t.googleHealth.never}</dd>
          </>
        )}
        {connected && lastError && (
          <>
            <dt className="text-muted-foreground">{t.googleHealth.lastError}</dt>
            <dd className="text-destructive">
              {t.googleHealth.errorText(lastError)}
              {lastErrorAt && <span className="text-muted-foreground"> · {lastErrorAt}</span>}
            </dd>
          </>
        )}
      </dl>

      {(!connected || needsReconnect) && (
        <div className="flex flex-col gap-2">
          <Button className="self-start" disabled={pending} onClick={connect}>
            {pending ? t.googleHealth.connecting : connected ? t.googleHealth.reconnect : t.googleHealth.connect}
          </Button>
          <p className="text-xs text-muted-foreground">{t.googleHealth.connectHint}</p>
        </div>
      )}

      {connected && (
        <div className="flex gap-2">
          <Button variant="outline" disabled={pending} onClick={sync}>
            {pending ? t.googleHealth.syncing : t.googleHealth.sync}
          </Button>
          <Button variant="destructive" disabled={pending} onClick={disconnect}>
            {t.googleHealth.disconnect}
          </Button>
        </div>
      )}
    </div>
  )
}
