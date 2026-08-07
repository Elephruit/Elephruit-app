/// The application frame: rail beside content from 720 up, bottom tabs below.
/// Content scrolls with the document — native find-in-page and scroll
/// restoration stay intact. A crashing page is contained to the content column.
/// ⌘K opens the command palette from anywhere.

import { useEffect, useState } from 'react'
import { Outlet } from 'react-router-dom'
import { CommandPalette } from '../components/CommandPalette'
import { ErrorBoundary } from './ErrorBoundary'
import { MobileTabBar } from './MobileTabBar'
import { NavRail } from './NavRail'

export function AppShell() {
  const [paletteOpen, setPaletteOpen] = useState(false)

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() === 'k' && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        setPaletteOpen((open) => !open)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <NavRail onSearch={() => setPaletteOpen(true)} />
      <div className="shell-content" id="main">
        <ErrorBoundary>
          <Outlet />
        </ErrorBoundary>
      </div>
      <MobileTabBar />
      {paletteOpen && <CommandPalette onClose={() => setPaletteOpen(false)} />}
    </div>
  )
}
