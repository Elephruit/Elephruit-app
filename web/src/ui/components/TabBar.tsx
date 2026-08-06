import { NavLink, useNavigate } from 'react-router-dom'
import { Icon } from './Icon'

const TABS = [
  { to: '/', label: 'Feed', icon: 'feed', end: true },
  { to: '/people', label: 'People', icon: 'people', end: false },
] as const

const TRAILING_TABS = [
  { to: '/followups', label: 'Follow-ups', icon: 'bell', end: false },
  { to: '/settings', label: 'Settings', icon: 'gear', end: false },
] as const

export function TabBar() {
  const navigate = useNavigate()

  return (
    <nav className="tab-bar">
      {TABS.map((tab) => (
        <NavLink key={tab.to} to={tab.to} end={tab.end} className="tab">
          <Icon name={tab.icon} />
          {tab.label}
        </NavLink>
      ))}
      <div className="tab tab-log">
        <button
          type="button"
          className="tab-log-circle"
          aria-label="Log an interaction"
          onClick={() => navigate('/capture')}
        >
          <Icon name="plus" size={24} />
        </button>
      </div>
      {TRAILING_TABS.map((tab) => (
        <NavLink key={tab.to} to={tab.to} end={tab.end} className="tab">
          <Icon name={tab.icon} />
          {tab.label}
        </NavLink>
      ))}
    </nav>
  )
}
