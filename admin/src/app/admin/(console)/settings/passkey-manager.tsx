'use client'

import { startRegistration, type PublicKeyCredentialCreationOptionsJSON } from '@simplewebauthn/browser'
import { useRouter } from 'next/navigation'
import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useT } from '@/i18n/client'
import { apiErrorText } from '@/lib/api-error-text'
import { post } from '@/lib/post'

import { deletePasskeyAction } from '../../actions'

interface Passkey {
  id: string
  name: string
  createdAt: string
  lastUsedAt: string
}

export function PasskeyManager({ passkeys }: { passkeys: Passkey[] }) {
  const t = useT()
  const router = useRouter()
  const [adding, setAdding] = useState(false)
  const [name, setName] = useState('')
  const [password, setPassword] = useState('')
  const [pending, startTransition] = useTransition()

  function add() {
    startTransition(async () => {
      try {
        const begin = await post<{ flowToken: string; options: PublicKeyCredentialCreationOptionsJSON }>(
          '/api/passkey/register/begin',
          { password }
        )
        const credential = await startRegistration({ optionsJSON: begin.options })
        await post('/api/passkey/register/finish', { flowToken: begin.flowToken, credential, name })
        toast.success(t.settings.passkeyAdded)
        setAdding(false)
        setName('')
        setPassword('')
        router.refresh()
      } catch (error) {
        if ((error as Error).name !== 'NotAllowedError') toast.error(apiErrorText(t, error))
      }
    })
  }

  function remove(id: string) {
    startTransition(async () => {
      const result = await deletePasskeyAction(id)
      if (result.ok) toast.success(result.message)
      else toast.error(result.message)
    })
  }

  return (
    <div className="flex flex-col gap-3">
      {passkeys.length === 0 && <p className="text-sm text-muted-foreground">{t.settings.noPasskeys}</p>}
      {passkeys.map((passkey) => (
        <div key={passkey.id} className="flex items-center gap-3 rounded-lg border px-3 py-2 text-sm">
          <div className="flex flex-col">
            <span>{passkey.name}</span>
            <span className="text-xs text-muted-foreground">{t.settings.passkeyMeta(passkey.createdAt, passkey.lastUsedAt)}</span>
          </div>
          <Button variant="destructive" size="sm" className="ml-auto" disabled={pending} onClick={() => remove(passkey.id)}>
            {t.common.delete}
          </Button>
        </div>
      ))}
      {adding ? (
        <div className="grid gap-3 rounded-lg border p-3 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="passkey-name">{t.settings.passkeyName}</Label>
            <Input id="passkey-name" value={name} placeholder={t.settings.passkeyNamePlaceholder} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="passkey-password">{t.settings.currentPassword}</Label>
            <Input
              id="passkey-password"
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>
          <div className="flex gap-2 sm:col-span-2">
            <Button disabled={pending || !password} onClick={add}>
              {pending ? t.settings.registering : t.settings.register}
            </Button>
            <Button variant="ghost" disabled={pending} onClick={() => setAdding(false)}>
              {t.common.cancel}
            </Button>
          </div>
        </div>
      ) : (
        <Button variant="outline" className="self-start" onClick={() => setAdding(true)}>
          {t.settings.addPasskey}
        </Button>
      )}
    </div>
  )
}
