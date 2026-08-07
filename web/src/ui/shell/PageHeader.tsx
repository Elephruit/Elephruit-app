/// The page's own header: title and context on the left, actions on the right,
/// an optional row of filters underneath. Sticky, so orientation survives long
/// timelines. Each page owns its header — there is no shell-level top bar to
/// plumb titles through.

import type { ReactNode } from 'react'

export function PageHeader({
  title,
  subtitle,
  actions,
  children,
}: {
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
  children?: ReactNode
}) {
  return (
    <header className="page-header">
      <div className="page-header-row">
        <div className="page-header-text">
          <h1 className="page-title">{title}</h1>
          {subtitle && <p className="page-subtitle">{subtitle}</p>}
        </div>
        {actions && <div className="page-header-actions">{actions}</div>}
      </div>
      {children}
    </header>
  )
}
