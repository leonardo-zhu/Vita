'use client'

import { useRouter } from 'next/navigation'
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

import { rollbackAction } from '../../../actions'

export function RollbackButton({ releaseId, version }: { releaseId: number; version: string }) {
  const t = useT()
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [pending, startTransition] = useTransition()

  function rollback() {
    startTransition(async () => {
      const result = await rollbackAction(releaseId)
      if (!result.ok) {
        toast.error(result.message)
        return
      }
      toast.success(result.message)
      setOpen(false)
      router.push('/admin/releases')
    })
  }

  return (
    <>
      <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
        {t.releases.rollbackButton}
      </Button>
      <AlertDialog open={open} onOpenChange={setOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.releases.rollbackTitle(version)}</AlertDialogTitle>
            <AlertDialogDescription>{t.releases.rollbackDescription(version)}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>{t.common.cancel}</AlertDialogCancel>
            <Button disabled={pending} onClick={rollback}>
              {pending ? t.editor.publishing : t.releases.rollback}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
