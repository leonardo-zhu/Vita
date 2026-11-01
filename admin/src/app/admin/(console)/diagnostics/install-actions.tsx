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

import { deleteInstallAction, setInstallRevokedAction, type ActionResult } from '../../actions'

export function InstallActions({ installId, revoked }: { installId: string; revoked: boolean }) {
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
        {revoked ? '解封' : '封禁'}
      </Button>
      <Button variant="destructive" size="sm" disabled={pending} onClick={() => setConfirming(true)}>
        删除数据
      </Button>
      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>删除这个安装的诊断数据？</AlertDialogTitle>
            <AlertDialogDescription>
              安装 {installId.slice(0, 8)} 的全部诊断记录会被删除，不能恢复。它之后再上报的数据仍会被接收。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>取消</AlertDialogCancel>
            <Button variant="destructive" disabled={pending} onClick={() => run(() => deleteInstallAction(installId))}>
              删除
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
