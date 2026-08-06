/// Drag-and-drop over the expanded composer. A depth counter keeps child
/// enter/leave churn from flickering the highlight; only real file drags
/// count; the drop is validated file-by-file by the controller. The visual
/// state lives on the composer root (data-drag) so the rail node and branch
/// highlight together with the region — no floating drop-zone card.

import { useRef, useState } from 'react'

function hasFiles(event: React.DragEvent): boolean {
  return [...event.dataTransfer.types].includes('Files')
}

export function AttachmentDropZone({
  onDropFiles,
  onDragChange,
  children,
}: {
  onDropFiles: (files: FileList) => void
  onDragChange: (active: boolean) => void
  children: React.ReactNode
}) {
  const depth = useRef(0)
  const [active, setActive] = useState(false)

  function update(next: number) {
    depth.current = next
    const nowActive = next > 0
    if (nowActive !== active) {
      setActive(nowActive)
      onDragChange(nowActive)
    }
  }

  return (
    <div
      className="attachment-dropzone"
      data-active={active || undefined}
      onDragEnter={(event) => {
        if (!hasFiles(event)) return
        event.preventDefault()
        update(depth.current + 1)
      }}
      onDragLeave={(event) => {
        if (!hasFiles(event)) return
        event.preventDefault()
        update(Math.max(0, depth.current - 1))
      }}
      onDragOver={(event) => {
        if (!hasFiles(event)) return
        event.preventDefault()
      }}
      onDrop={(event) => {
        if (!hasFiles(event)) return
        event.preventDefault()
        update(0)
        if (event.dataTransfer.files.length > 0) onDropFiles(event.dataTransfer.files)
      }}
    >
      {children}
      {active && (
        <p className="attachment-drop-hint" aria-hidden="true">
          Drop files to add them
        </p>
      )}
    </div>
  )
}
