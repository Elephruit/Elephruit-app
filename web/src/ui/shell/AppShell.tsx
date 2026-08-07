/// The application frame: rail beside content from 720 up, bottom tabs below.
/// Content scrolls with the document while the desktop rail stays fixed to
/// the visible viewport. Native find-in-page and scroll restoration stay intact.
/// A crashing page is contained to the content column.
/// ⌘K opens the command palette and ⌘J opens Quick capture from anywhere.

import { useEffect, useState } from 'react'
import { Outlet, useNavigate } from 'react-router-dom'
import { CommandPalette } from '../components/CommandPalette'
import { ErrorBoundary } from './ErrorBoundary'
import { MobileTabBar } from './MobileTabBar'
import { NavRail } from './NavRail'

export function AppShell() {
  const navigate = useNavigate()
  const [paletteOpen, setPaletteOpen] = useState(false)

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (!(event.metaKey || event.ctrlKey)) return
      const key = event.key.toLowerCase()
      if (key === 'k') {
        event.preventDefault()
        setPaletteOpen((open) => !open)
      } else if (key === 'j') {
        event.preventDefault()
        setPaletteOpen(false)
        navigate('/?capture=1')
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [navigate])

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <NavRail onSearch={() => setPaletteOpen(true)} onCapture={() => navigate('/?capture=1')} />
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
