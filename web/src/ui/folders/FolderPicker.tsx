/// Choosing where something is filed.
///
/// This replaces a native `<select>` whose options were full paths — "Travel",
/// then "Travel / Chicago, October", then "Travel / Chicago, October / Museums"
/// — which repeats every parent's name once per descendant and turns a filing
/// system into a wall of near-identical strings. It read badly with three
/// folders and would have been unusable with thirty.
///
/// What replaces it:
///
/// - **The indent says the hierarchy**, so each row is just a name.
/// - **A search field**, because past a dozen folders scanning is slower than
///   typing. It appears only when there is enough to be worth filtering.
/// - **The list scrolls inside the popover**, so the control's size stops
///   growing at a fixed height however many folders exist.
/// - **A filtered row still shows its path**, in small type beneath the name —
///   the indent is meaningless once the tree is cut up, and "Museums" alone
///   does not say which trip.

import { useEffect, useMemo, useRef, useState } from 'react'
import { buildTree, flattenTree, folderTint, pathLabel, type Folder } from '../../domain/folder'
import { foldedForMatching } from '../../domain/person'
import { Icon } from '../components/Icon'

const SEARCH_APPEARS_ABOVE = 8

export function FolderPicker({
  folders,
  value,
  onChange,
  label = 'Folder',
  emptyLabel = 'Unfiled',
  disabled = false,
}: {
  folders: Folder[]
  value: string | null
  onChange: (folderID: string | null) => void
  label?: string
  emptyLabel?: string
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const root = useRef<HTMLDivElement>(null)

  const selected = folders.find((folder) => folder.id === value) ?? null

  const rows = useMemo(() => {
    const all = flattenTree(buildTree(folders))
    const folded = foldedForMatching(query)
    if (!folded) return all.map((node) => ({ ...node, showPath: false }))
    return all
      .filter((node) => foldedForMatching(node.folder.title).includes(folded))
      .map((node) => ({ ...node, depth: 0, showPath: true }))
  }, [folders, query])

  // Close on an outside click or Escape. Both, because a popover that only
  // answers one of them is a popover you get stuck in.
  useEffect(() => {
    if (!open) return
    const onPointerDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false)
    }
    window.document.addEventListener('mousedown', onPointerDown)
    window.document.addEventListener('keydown', onKeyDown)
    return () => {
      window.document.removeEventListener('mousedown', onPointerDown)
      window.document.removeEventListener('keydown', onKeyDown)
    }
  }, [open])

  function choose(folderID: string | null) {
    onChange(folderID)
    setOpen(false)
    setQuery('')
  }

  return (
    <div className="folder-picker" ref={root}>
      <button
        type="button"
        className="folder-picker-button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={label}
        disabled={disabled}
        onClick={() => setOpen((current) => !current)}
      >
        <span
          className="folder-picker-glyph"
          style={
            selected ? ({ '--tint': folderTint(selected.colorName) } as React.CSSProperties) : undefined
          }
        >
          <Icon name="folder" size={14} />
        </span>
        <span className="folder-picker-value">{selected?.title ?? emptyLabel}</span>
        <Icon name="chevron-down" size={13} />
      </button>

      {open && (
        <div className="folder-popover" role="listbox" aria-label={label}>
          {folders.length >= SEARCH_APPEARS_ABOVE && (
            <div className="folder-popover-search">
              <Icon name="search" size={13} />
              <input
                autoFocus
                className="folder-popover-input"
                placeholder="Find a folder…"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
              />
            </div>
          )}

          <div className="folder-popover-list">
            <button
              type="button"
              role="option"
              aria-selected={value === null}
              className="folder-option"
              onClick={() => choose(null)}
            >
              <span className="folder-option-name">{emptyLabel}</span>
              {value === null && <Icon name="check" size={13} />}
            </button>

            {rows.map(({ folder, depth, showPath }) => (
              <button
                key={folder.id}
                type="button"
                role="option"
                aria-selected={folder.id === value}
                className="folder-option"
                style={{ '--depth': depth } as React.CSSProperties}
                onClick={() => choose(folder.id)}
              >
                <span
                  className="folder-picker-glyph"
                  style={{ '--tint': folderTint(folder.colorName) } as React.CSSProperties}
                >
                  <Icon name="folder" size={13} />
                </span>
                <span className="folder-option-text">
                  <span className="folder-option-name">{folder.title}</span>
                  {showPath && <span className="folder-option-path">{pathLabel(folders, folder.id)}</span>}
                </span>
                {folder.id === value && <Icon name="check" size={13} />}
              </button>
            ))}

            {rows.length === 0 && <p className="folder-popover-empty">No folder matches “{query}”.</p>}
          </div>
        </div>
      )}
    </div>
  )
}
