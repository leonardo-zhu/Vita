'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useT } from '@/i18n/client'

import { createDeviceAction, revokeDeviceAction } from '../../actions'

interface DeviceRow {
  id: string
  name: string
  createdAt: string
  lastUsedAt: string | null
  revokedAt: string | null
}

export function DeviceManager({ devices, serverUrl }: { devices: DeviceRow[]; serverUrl: string }) {
  const t = useT()
  const [name, setName] = useState('')
  const [issued, setIssued] = useState<{ name: string; token: string } | null>(null)
  const [pending, startTransition] = useTransition()

  function create() {
    startTransition(async () => {
      const result = await createDeviceAction(name)
      if (!result.ok) {
        toast.error(result.message)
        return
      }
      setIssued({ name: result.deviceName, token: result.token })
      setName('')
    })
  }

  function revoke(device: DeviceRow) {
    if (!window.confirm(t.devices.revokeConfirm(device.name))) return
    startTransition(async () => {
      const result = await revokeDeviceAction(device.id, device.name)
      if (result.ok) toast.success(result.message)
      else toast.error(result.message)
    })
  }

  async function copy(text: string) {
    await navigator.clipboard.writeText(text)
    toast.success(t.devices.copied)
  }

  return (
    <div className="flex flex-col gap-4">
      {issued && (
        <div className="flex flex-col gap-3 rounded-lg border border-primary/40 bg-primary/5 p-3 text-sm">
          <div className="font-medium">{t.devices.tokenTitle(issued.name)}</div>
          <p className="text-muted-foreground">{t.devices.tokenHint}</p>
          <CopyRow label={t.devices.serverUrl} value={serverUrl} onCopy={copy} copyLabel={t.devices.copy} />
          <CopyRow label={t.devices.token} value={issued.token} onCopy={copy} copyLabel={t.devices.copy} secret />
          <Button variant="outline" size="sm" className="self-start" onClick={() => setIssued(null)}>
            {t.devices.done}
          </Button>
        </div>
      )}

      {devices.length === 0 && <p className="text-sm text-muted-foreground">{t.devices.empty}</p>}
      {devices.map((device) => (
        <div key={device.id} className="flex items-center gap-3 rounded-lg border px-3 py-2 text-sm">
          <div className="flex min-w-0 flex-col">
            <span className="flex items-center gap-2">
              {device.name}
              {device.revokedAt && <Badge variant="secondary">{t.devices.revokedAt(device.revokedAt)}</Badge>}
            </span>
            <span className="text-xs text-muted-foreground">
              {t.devices.created} {device.createdAt} · {t.devices.lastUsed} {device.lastUsedAt ?? t.devices.never}
            </span>
          </div>
          {!device.revokedAt && (
            <Button variant="destructive" size="sm" className="ml-auto" disabled={pending} onClick={() => revoke(device)}>
              {t.devices.revoke}
            </Button>
          )}
        </div>
      ))}

      <div className="flex flex-col gap-1.5 sm:flex-row sm:items-end sm:gap-2">
        <div className="flex flex-1 flex-col gap-1.5">
          <Label htmlFor="device-name">{t.devices.name}</Label>
          <Input id="device-name" value={name} maxLength={64} placeholder={t.devices.namePlaceholder} onChange={(e) => setName(e.target.value)} />
        </div>
        <Button disabled={pending || !name.trim()} onClick={create}>
          {pending ? t.devices.creating : t.devices.create}
        </Button>
      </div>
    </div>
  )
}

function CopyRow({ label, value, onCopy, copyLabel, secret = false }: { label: string; value: string; onCopy: (value: string) => void; copyLabel: string; secret?: boolean }) {
  return (
    <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-3">
      <span className="w-24 shrink-0 text-muted-foreground">{label}</span>
      <code className={`min-w-0 flex-1 rounded bg-muted px-2 py-1 font-mono text-xs break-all ${secret ? 'select-all' : ''}`}>{value}</code>
      <Button variant="outline" size="sm" onClick={() => onCopy(value)}>
        {copyLabel}
      </Button>
    </div>
  )
}
