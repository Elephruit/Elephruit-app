/// The content column. Width is a per-task choice, not a global constant:
/// narrow for forms and settings, reading for the feed, wide for directories
/// and workspaces.

import type { ReactNode } from 'react'

export type PageWidth = 'narrow' | 'reading' | 'wide'

export function PageScaffold({ width = 'reading', children }: { width?: PageWidth; children: ReactNode }) {
  return (
    <main className="page-scaffold" data-width={width}>
      {children}
    </main>
  )
}
