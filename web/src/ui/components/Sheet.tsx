/// The focused side surface for creation and editing flows — a right-anchored
/// panel from 900px up, a bottom sheet below. Built on the native <dialog> so
/// the focus trap, Escape, focus return, and the top layer come from the
/// platform, exactly like Dialog. `onClose` is a close *request*: the caller
/// decides whether to unmount, keep editing, or first show an inline discard
/// confirmation in its footer.

import { useEffect, useRef } from 'react'
import { Icon } from './Icon'

export function Sheet({
  title,
  onClose,
  width = 480,
  footer,
  children,
}: {
  title: string
  onClose: () => void
  /// Panel width from 900px up; ignored by the bottom-sheet layout.
  width?: number
  /// Sticky footer content — actions, inline confirmations.
  footer?: React.ReactNode
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
      className="sheet"
      style={{ '--sheet-width': `${width}px` } as React.CSSProperties}
      aria-label={title}
      onCancel={(event) => {
        // Keep React state the owner of open/closed, same as Dialog.
        event.preventDefault()
        onClose()
      }}
      onClick={(event) => {
        if (event.target === ref.current) onClose()
      }}
    >
      <header className="sheet-header">
        <h2 className="sheet-title">{title}</h2>
        <button type="button" className="icon-button" aria-label={`Close ${title}`} onClick={onClose}>
          <Icon name="x" size={16} />
        </button>
      </header>
      <div className="sheet-body">{children}</div>
      {footer && <footer className="sheet-footer">{footer}</footer>}
    </dialog>
  )
}
