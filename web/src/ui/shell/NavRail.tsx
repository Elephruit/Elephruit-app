/// The desktop navigation rail: identity, the primary capture action, the three
/// destinations, and settings anchored at the bottom. From 720 it is an icon
/// rail; from 1024 it carries labels. Below 720 it is absent — MobileTabBar
/// takes over.

import { NavLink, useNavigate } from 'react-router-dom'
import { Icon } from '../components/Icon'

const DESTINATIONS = [
  { to: '/', label: 'Feed', icon: 'feed', end: true },
  { to: '/people', label: 'People', icon: 'people', end: false },
  { to: '/followups', label: 'Follow-ups', icon: 'bell', end: false },
] as const

export function NavRail({ onSearch }: { onSearch: () => void }) {
  const navigate = useNavigate()
  const isMac = navigator.platform.toUpperCase().includes('MAC')

  return (
    <nav className="nav-rail" aria-label="Primary">
      <div className="rail-brand">
        <img src="/favicon.svg" alt="" width={26} height={26} />
        <span className="rail-brand-word">Elephruit</span>
      </div>

      <button className="rail-capture" onClick={() => navigate('/capture')} title="Log an interaction">
        <Icon name="plus" size={16} />
        <span className="rail-label">Log interaction</span>
      </button>

      {DESTINATIONS.map((destination) => (
        <NavLink
          key={destination.to}
          to={destination.to}
          end={destination.end}
          className="rail-item"
          title={destination.label}
        >
          <Icon name={destination.icon} size={17} />
          <span className="rail-label">{destination.label}</span>
        </NavLink>
      ))}

      <button className="rail-search" onClick={onSearch} title="Search">
        <Icon name="search" size={15} />
        <span className="rail-label">Search</span>
        <kbd className="rail-kbd">{isMac ? '⌘K' : 'Ctrl K'}</kbd>
      </button>

      <div className="rail-foot">
        <NavLink to="/settings" className="rail-item" title="Settings">
          <Icon name="gear" size={17} />
          <span className="rail-label">Settings</span>
        </NavLink>
      </div>
    </nav>
  )
}
