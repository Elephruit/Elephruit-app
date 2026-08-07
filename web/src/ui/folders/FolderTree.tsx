/// The folder tree, as a column you browse rather than a control you open.
///
/// A picker answers "where does this go?" once. A tree answers "what is in
/// here?" continuously, which is the question a filing system is actually for —
/// so the Notes list gets this beside it instead of a dropdown above it.
///
/// Branches collapse, and that is the whole defence against bloat: a hundred
/// folders is still six rows if they are nested and shut. Collapse state is
/// keyed by folder id and held by the caller, so it survives navigating away
/// and back.

import { buildTree, folderTint, type Folder, type FolderNode } from '../../domain/folder'
import { Icon } from '../components/Icon'

export interface FolderTreeProps {
  folders: Folder[]
  /// `null` selects "everything" — the row above the tree.
  selected: string | null
  onSelect: (folderID: string | null) => void
  /// How many things each folder directly holds. Absent means show no count.
  counts?: Map<string, number>
  collapsed: Set<string>
  onToggleCollapsed: (folderID: string) => void
  everythingLabel?: string
  everythingCount?: number
}

export function FolderTree({
  folders,
  selected,
  onSelect,
  counts,
  collapsed,
  onToggleCollapsed,
  everythingLabel = 'All notes',
  everythingCount,
}: FolderTreeProps) {
  const tree = buildTree(folders)

  const renderNode = (node: FolderNode): React.ReactNode => {
    const isCollapsed = collapsed.has(node.folder.id)
    const count = counts?.get(node.folder.id) ?? 0
    return (
      <div key={node.folder.id}>
        <div
          className="folder-tree-row"
          data-selected={node.folder.id === selected || undefined}
          style={{ '--depth': node.depth } as React.CSSProperties}
        >
          {/* The twisty sits in the gutter rather than in the row's flow, so a
              folder with children and one without line up with each other. */}
          {node.children.length > 0 ? (
            <button
              type="button"
              className="folder-tree-twisty"
              aria-label={isCollapsed ? `Expand ${node.folder.title}` : `Collapse ${node.folder.title}`}
              aria-expanded={!isCollapsed}
              onClick={() => onToggleCollapsed(node.folder.id)}
            >
              <Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size={12} />
            </button>
          ) : (
            <span className="folder-tree-twisty" aria-hidden="true" />
          )}

          <button type="button" className="folder-tree-main" onClick={() => onSelect(node.folder.id)}>
            <span
              className="folder-picker-glyph"
              style={{ '--tint': folderTint(node.folder.colorName) } as React.CSSProperties}
            >
              <Icon name="folder" size={13} />
            </span>
            <span className="folder-tree-name">{node.folder.title}</span>
            {/* Absent, not zero. A count of nothing is a number to read and
                then disregard, on every empty folder, forever. */}
            {count > 0 && <span className="folder-tree-count">{count}</span>}
          </button>
        </div>
        {!isCollapsed && node.children.map(renderNode)}
      </div>
    )
  }

  return (
    <nav className="folder-tree" aria-label="Folders">
      <div className="folder-tree-row" data-selected={selected === null || undefined}>
        <span className="folder-tree-twisty" aria-hidden="true" />
        <button type="button" className="folder-tree-main" onClick={() => onSelect(null)}>
          <span className="folder-picker-glyph">
            <Icon name="note" size={13} />
          </span>
          <span className="folder-tree-name">{everythingLabel}</span>
          {everythingCount !== undefined && everythingCount > 0 && (
            <span className="folder-tree-count">{everythingCount}</span>
          )}
        </button>
      </div>
      {tree.map(renderNode)}
    </nav>
  )
}
