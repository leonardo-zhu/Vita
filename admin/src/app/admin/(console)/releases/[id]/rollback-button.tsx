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

import { rollbackAction } from '../../../actions'

export function RollbackButton({ releaseId, version }: { releaseId: number; version: string }) {
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
        回滚到这个版本…
      </Button>
      <AlertDialog open={open} onOpenChange={setOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>回滚到 {version}？</AlertDialogTitle>
            <AlertDialogDescription>
              会用新的版本号重新发布 {version} 的内容，立即对外生效；当前未发布的草稿会被丢弃。
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>取消</AlertDialogCancel>
            <Button disabled={pending} onClick={rollback}>
              {pending ? '发布中…' : '回滚'}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
