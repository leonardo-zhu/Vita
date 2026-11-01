'use client'

import { startRegistration, type PublicKeyCredentialCreationOptionsJSON } from '@simplewebauthn/browser'
import { useRouter } from 'next/navigation'
import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { post } from '@/lib/post'

import { deletePasskeyAction } from '../../actions'

interface Passkey {
  id: string
  name: string
  createdAt: string
  lastUsedAt: string
}

export function PasskeyManager({ passkeys }: { passkeys: Passkey[] }) {
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
        toast.success('已添加 Passkey')
        setAdding(false)
        setName('')
        setPassword('')
        router.refresh()
      } catch (error) {
        if ((error as Error).name !== 'NotAllowedError') toast.error((error as Error).message)
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
      {passkeys.length === 0 && <p className="text-sm text-muted-foreground">还没有注册 Passkey。</p>}
      {passkeys.map((passkey) => (
        <div key={passkey.id} className="flex items-center gap-3 rounded-lg border px-3 py-2 text-sm">
          <div className="flex flex-col">
            <span>{passkey.name}</span>
            <span className="text-xs text-muted-foreground">
              添加于 {passkey.createdAt}，最近使用 {passkey.lastUsedAt}
            </span>
          </div>
          <Button variant="destructive" size="sm" className="ml-auto" disabled={pending} onClick={() => remove(passkey.id)}>
            删除
          </Button>
        </div>
      ))}
      {adding ? (
        <div className="grid gap-3 rounded-lg border p-3 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="passkey-name">名称</Label>
            <Input id="passkey-name" value={name} placeholder="如 MacBook" onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="passkey-password">当前密码</Label>
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
              {pending ? '等待验证…' : '注册'}
            </Button>
            <Button variant="ghost" disabled={pending} onClick={() => setAdding(false)}>
              取消
            </Button>
          </div>
        </div>
      ) : (
        <Button variant="outline" className="self-start" onClick={() => setAdding(true)}>
          添加 Passkey
        </Button>
      )}
    </div>
  )
}
