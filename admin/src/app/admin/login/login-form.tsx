'use client'

import { startAuthentication, type PublicKeyCredentialRequestOptionsJSON } from '@simplewebauthn/browser'
import { KeyRound } from 'lucide-react'
import { useRouter } from 'next/navigation'
import { useActionState, useState } from 'react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { post } from '@/lib/post'

import { loginAction } from '../actions'

export function LoginForm({ passkeyAvailable }: { passkeyAvailable: boolean }) {
  const router = useRouter()
  const [state, action, pending] = useActionState(loginAction, null)
  const [passkeyError, setPasskeyError] = useState<string | null>(null)
  const [passkeyPending, setPasskeyPending] = useState(false)

  async function loginWithPasskey() {
    setPasskeyError(null)
    setPasskeyPending(true)
    try {
      const begin = await post<{ flowToken: string; options: PublicKeyCredentialRequestOptionsJSON }>(
        '/api/passkey/login/begin',
        {}
      )
      const credential = await startAuthentication({ optionsJSON: begin.options })
      await post('/api/passkey/login/finish', { flowToken: begin.flowToken, credential })
      router.replace('/admin')
      router.refresh()
    } catch (error) {
      // 用户自己取消时浏览器抛 NotAllowedError，不用提示
      if ((error as Error).name !== 'NotAllowedError') setPasskeyError((error as Error).message)
    } finally {
      setPasskeyPending(false)
    }
  }

  const error = passkeyError ?? (state && !state.ok ? state.message : null)

  return (
    <Card className="w-full max-w-sm">
      <CardHeader>
        <CardTitle>Vita Admin</CardTitle>
        <CardDescription>远程配置的编辑与发布</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {passkeyAvailable && (
          <>
            <Button variant="outline" size="lg" onClick={loginWithPasskey} disabled={passkeyPending}>
              <KeyRound />
              {passkeyPending ? '等待验证…' : '用 Passkey 登录'}
            </Button>
            <div className="flex items-center gap-3 text-xs text-muted-foreground">
              <Separator className="flex-1" />或<Separator className="flex-1" />
            </div>
          </>
        )}
        <form action={action} className="flex flex-col gap-3">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="username">账号</Label>
            <Input id="username" name="username" autoComplete="username" required />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="password">密码</Label>
            <Input id="password" name="password" type="password" autoComplete="current-password" required />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
          <Button type="submit" size="lg" disabled={pending}>
            {pending ? '登录中…' : '登录'}
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}
