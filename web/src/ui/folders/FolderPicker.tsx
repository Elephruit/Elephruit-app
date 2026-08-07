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

import { useEffect, useMemo, useRef, useState, type MouseEventHandler, type Ref } from 'react'
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
  compact = false,
  className,
  buttonRef,
  onButtonMouseDown,
  openOnFocus = false,
  onOpenChange,
  onTabBackward,
  onTabForward,
}: {
  folders: Folder[]
  value: string | null
  onChange: (folderID: string | null) => void
  label?: string
  emptyLabel?: string
  disabled?: boolean
  compact?: boolean
  className?: string
  buttonRef?: Ref<HTMLButtonElement>
  onButtonMouseDown?: MouseEventHandler<HTMLButtonElement>
  openOnFocus?: boolean
  onOpenChange?: (open: boolean) => void
  onTabBackward?: () => void
  onTabForward?: () => void
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const root = useRef<HTMLDivElement>(null)
  const suppressOpenOnFocus = useRef(false)

  const selected = folders.find((folder) => folder.id === value) ?? null

  function triggerButton() {
    return root.current?.querySelector<HTMLButtonElement>('.folder-picker-button') ?? null
  }

  function optionButtons() {
    return Array.from(root.current?.querySelectorAll<HTMLButtonElement>('[role="option"]') ?? [])
  }

  function focusOption(index: number) {
    const options = optionButtons()
    if (options.length === 0) return
    options[(index + options.length) % options.length].focus()
  }

  function openAndFocus(direction: 'first' | 'last') {
    setOpen(true)
    onOpenChange?.(true)
    window.setTimeout(() => {
      const options = optionButtons()
      const selectedIndex = options.findIndex((option) => option.getAttribute('aria-selected') === 'true')
      if (selectedIndex >= 0) focusOption(selectedIndex)
      else focusOption(direction === 'first' ? 0 : options.length - 1)
    }, 0)
  }

  function focusTriggerWithoutOpening() {
    suppressOpenOnFocus.current = true
    triggerButton()?.focus()
    window.setTimeout(() => {
      suppressOpenOnFocus.current = false
    }, 0)
  }

  function closeAndFocusTrigger() {
    setOpen(false)
    onOpenChange?.(false)
    setQuery('')
    window.setTimeout(focusTriggerWithoutOpening, 0)
  }

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
      if (!root.current?.contains(event.target as Node)) {
        setOpen(false)
        onOpenChange?.(false)
      }
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        setOpen(false)
        onOpenChange?.(false)
        setQuery('')
        window.setTimeout(() => {
          suppressOpenOnFocus.current = true
          root.current?.querySelector<HTMLButtonElement>('.folder-picker-button')?.focus()
          window.setTimeout(() => {
            suppressOpenOnFocus.current = false
          }, 0)
        }, 0)
      }
    }
    window.document.addEventListener('mousedown', onPointerDown)
    window.document.addEventListener('keydown', onKeyDown)
    return () => {
      window.document.removeEventListener('mousedown', onPointerDown)
      window.document.removeEventListener('keydown', onKeyDown)
    }
  }, [onOpenChange, open])

  function choose(folderID: string | null) {
    onChange(folderID)
    setOpen(false)
    onOpenChange?.(false)
    setQuery('')
    window.setTimeout(focusTriggerWithoutOpening, 0)
  }

  function moveOptionFocus(event: React.KeyboardEvent<HTMLButtonElement>, index: number) {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      focusOption(index + (event.key === 'ArrowDown' ? 1 : -1))
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault()
      const options = optionButtons()
      focusOption(event.key === 'Home' ? 0 : options.length - 1)
    }
  }

  return (
    <div
      className={['folder-picker', className].filter(Boolean).join(' ')}
      ref={root}
      onKeyDown={(event) => {
        if (event.key !== 'Escape' || !open) return
        event.preventDefault()
        event.stopPropagation()
        closeAndFocusTrigger()
      }}
    >
      <button
        ref={buttonRef}
        type="button"
        className="folder-picker-button"
        data-compact={compact || undefined}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={compact ? `${label}: ${selected?.title ?? emptyLabel}` : label}
        title={compact ? `${label}: ${selected?.title ?? emptyLabel}` : undefined}
        disabled={disabled}
        onMouseDown={onButtonMouseDown}
        onFocus={() => {
          if (suppressOpenOnFocus.current || !openOnFocus || open) return
          setOpen(true)
          onOpenChange?.(true)
        }}
        onClick={() => {
          setOpen((current) => {
            onOpenChange?.(!current)
            return !current
          })
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault()
            openAndFocus(event.key === 'ArrowDown' ? 'first' : 'last')
          } else if (event.key === 'Tab') {
            if (event.shiftKey && onTabBackward) {
              event.preventDefault()
              setOpen(false)
              onOpenChange?.(false)
              onTabBackward()
            } else if (!event.shiftKey && onTabForward) {
              event.preventDefault()
              setOpen(false)
              onOpenChange?.(false)
              onTabForward()
            }
          }
        }}
      >
        <span
          className="folder-picker-glyph"
          style={
            selected ? ({ '--tint': folderTint(selected.colorName) } as React.CSSProperties) : undefined
          }
        >
          <Icon name="folder" size={14} />
        </span>
        {!compact && <span className="folder-picker-value">{selected?.title ?? emptyLabel}</span>}
        {!compact && <Icon name="chevron-down" size={13} />}
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
                onKeyDown={(event) => {
                  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
                  event.preventDefault()
                  const options = optionButtons()
                  focusOption(event.key === 'ArrowDown' ? 0 : options.length - 1)
                }}
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
              onKeyDown={(event) => moveOptionFocus(event, 0)}
            >
              <span className="folder-option-name">{emptyLabel}</span>
              {value === null && <Icon name="check" size={13} />}
            </button>

            {rows.map(({ folder, depth, showPath }, index) => (
              <button
                key={folder.id}
                type="button"
                role="option"
                aria-selected={folder.id === value}
                className="folder-option"
                style={{ '--depth': depth } as React.CSSProperties}
                onClick={() => choose(folder.id)}
                onKeyDown={(event) => moveOptionFocus(event, index + 1)}
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
