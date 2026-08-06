import { useEffect } from 'react'

/// The composer surface: slides over the page, closes on the backdrop or Escape.
/// Whether closing saves or discards is the caller's decision, not the sheet's.
export function Sheet({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: React.ReactNode
}) {
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  return (
    <div
      className="sheet-backdrop"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div className="sheet" role="dialog" aria-label={title}>
        <h2 className="sheet-title">{title}</h2>
        {children}
      </div>
    </div>
  )
}
