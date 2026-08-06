/// The canonical breakpoints. Media queries cannot read custom properties, so
/// these numbers are the single source of truth and tokens.css mirrors them in
/// a comment: 720 mobile→tablet, 1024 tablet→desktop rail, 1280 wide.

import { useSyncExternalStore } from 'react'

export const BREAKPOINTS = {
  tablet: 720,
  desktop: 1024,
  wide: 1280,
} as const

export type Viewport = 'mobile' | 'tablet' | 'desktop' | 'wide'

const QUERIES: Array<[Viewport, string]> = [
  ['wide', `(min-width: ${BREAKPOINTS.wide}px)`],
  ['desktop', `(min-width: ${BREAKPOINTS.desktop}px)`],
  ['tablet', `(min-width: ${BREAKPOINTS.tablet}px)`],
]

function currentViewport(): Viewport {
  for (const [name, query] of QUERIES) {
    if (window.matchMedia(query).matches) return name
  }
  return 'mobile'
}

function subscribe(onChange: () => void): () => void {
  const lists = QUERIES.map(([, query]) => window.matchMedia(query))
  for (const list of lists) list.addEventListener('change', onChange)
  return () => {
    for (const list of lists) list.removeEventListener('change', onChange)
  }
}

export function useViewport(): Viewport {
  return useSyncExternalStore(subscribe, currentViewport)
}
