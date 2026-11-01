'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import { useT } from '@/i18n/client'

import { deleteInstallAction, setInstallRevokedAction, type ActionResult } from '../../actions'

export function InstallActions({ installId, revoked }: { installId: string; revoked: boolean }) {
  const t = useT()
  const [pending, startTransition] = useTransition()
  const [confirming, setConfirming] = useState(false)

  function run(action: () => Promise<ActionResult>) {
    startTransition(async () => {
      const result = await action()
      if (result.ok) toast.success(result.message)
      else toast.error(result.message)
      setConfirming(false)
    })
  }

  return (
    <div className="flex justify-end gap-1">
      <Button variant="ghost" size="sm" disabled={pending} onClick={() => run(() => setInstallRevokedAction(installId, !revoked))}>
        {revoked ? t.diagnostics.restore : t.diagnostics.revoke}
      </Button>
      <Button variant="destructive" size="sm" disabled={pending} onClick={() => setConfirming(true)}>
        {t.diagnostics.deleteData}
      </Button>
      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.diagnostics.deleteTitle}</AlertDialogTitle>
            <AlertDialogDescription>{t.diagnostics.deleteDescription(installId.slice(0, 8))}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>{t.common.cancel}</AlertDialogCancel>
            <Button variant="destructive" disabled={pending} onClick={() => run(() => deleteInstallAction(installId))}>
              {t.common.delete}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
