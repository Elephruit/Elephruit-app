/// The application frame: rail beside content from 720 up, bottom tabs below.
/// Content scrolls with the document — native find-in-page and scroll
/// restoration stay intact. A crashing page is contained to the content column.

import { Outlet } from 'react-router-dom'
import { ErrorBoundary } from './ErrorBoundary'
import { MobileTabBar } from './MobileTabBar'
import { NavRail } from './NavRail'

export function AppShell() {
  return (
    <div className="app-shell">
      <NavRail />
      <div className="shell-content">
        <ErrorBoundary>
          <Outlet />
        </ErrorBoundary>
      </div>
      <MobileTabBar />
    </div>
  )
}
