/// Modal editing surface on the native <dialog> element — the focus trap, the
/// Escape key, focus return, and the top layer all come from the platform.
/// Centered panel from 720; bottom drawer below. Whether closing saves or
/// discards is the caller's decision, same as the sheet it replaces.

import { useEffect, useRef } from 'react'

export function Dialog({
  title,
  onClose,
  size = 'regular',
  children,
}: {
  title: string
  onClose: () => void
  size?: 'regular' | 'wide'
  children: React.ReactNode
}) {
  const ref = useRef<HTMLDialogElement>(null)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
    return () => dialog?.close()
  }, [])

  return (
    <dialog
      ref={ref}
      className="dialog"
      data-size={size}
      aria-label={title}
      onCancel={(event) => {
        // Keep React state the owner of open/closed: veto the native close and
        // let the caller unmount us instead.
        event.preventDefault()
        onClose()
      }}
      onClick={(event) => {
        // Clicks on ::backdrop arrive with the dialog itself as the target;
        // clicks inside land on descendants.
        if (event.target === ref.current) onClose()
      }}
    >
      <div className="dialog-inner">
        <h2 className="dialog-title">{title}</h2>
        {children}
      </div>
    </dialog>
  )
}
