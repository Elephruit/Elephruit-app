/// The bottom navigation, mobile only — the rail takes over from 720. Same
/// destinations, plus the center capture button.

import { NavLink, useNavigate } from 'react-router-dom'
import { Icon } from '../components/Icon'

const TABS = [
  { to: '/', label: 'Feed', icon: 'feed', end: true },
  { to: '/people', label: 'People', icon: 'people', end: false },
] as const

const TRAILING_TABS = [
  { to: '/followups', label: 'Follow-ups', icon: 'bell' },
  { to: '/settings', label: 'Settings', icon: 'gear' },
] as const

export function MobileTabBar() {
  const navigate = useNavigate()

  return (
    <nav className="tab-bar" aria-label="Primary">
      {TABS.map((tab) => (
        <NavLink key={tab.to} to={tab.to} end={tab.end} className="tab">
          <Icon name={tab.icon} size={22} />
          {tab.label}
        </NavLink>
      ))}
      <div className="tab tab-log">
        <button className="tab-log-circle" aria-label="Record a memory" onClick={() => navigate('/?capture=1')}>
          <Icon name="plus" size={24} />
        </button>
      </div>
      {TRAILING_TABS.map((tab) => (
        <NavLink key={tab.to} to={tab.to} className="tab">
          <Icon name={tab.icon} size={22} />
          {tab.label}
        </NavLink>
      ))}
    </nav>
  )
}
