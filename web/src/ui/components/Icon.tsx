/// The hand-drawn icon set — a dozen 24×24 stroke glyphs standing in for the
/// Mac app's SF Symbols. Approximate fidelity by design; one family by rule.

const PATHS: Record<string, React.ReactNode> = {
  feed: (
    <>
      <circle cx="5" cy="6" r="1.6" fill="currentColor" stroke="none" />
      <circle cx="5" cy="12" r="1.6" fill="currentColor" stroke="none" />
      <circle cx="5" cy="18" r="1.6" fill="currentColor" stroke="none" />
      <path d="M10 6h9M10 12h9M10 18h9" />
    </>
  ),
  people: (
    <>
      <circle cx="9" cy="8.5" r="3.2" />
      <path d="M3.5 19c.8-3.2 3-4.8 5.5-4.8s4.7 1.6 5.5 4.8" />
      <path d="M15.5 5.8a3.2 3.2 0 0 1 0 5.4M17.6 14.6c1.6.8 2.6 2.3 3 4.4" />
    </>
  ),
  plus: <path d="M12 5v14M5 12h14" />,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  circle: <circle cx="12" cy="12" r="8.5" />,
  'check-circle': (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M8.5 12.3l2.4 2.4 4.8-5" />
    </>
  ),
  gear: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3.5v2.2M12 18.3v2.2M3.5 12h2.2M18.3 12h2.2M6 6l1.6 1.6M16.4 16.4L18 18M18 6l-1.6 1.6M7.6 16.4L6 18" />
    </>
  ),
  'in-person': (
    <>
      <circle cx="12" cy="8" r="3.4" />
      <path d="M5.5 20c1-3.6 3.5-5.4 6.5-5.4s5.5 1.8 6.5 5.4" />
    </>
  ),
  phone: (
    <path d="M7 4h3l1.5 4-2 1.5a11 11 0 0 0 5 5L16 12.5l4 1.5v3c0 1-1 2-2 2C10.5 19 5 13.5 5 6c0-1 1-2 2-2z" />
  ),
  video: (
    <>
      <rect x="3.5" y="7" width="12" height="10" rx="2" />
      <path d="M15.5 11l5-3v8l-5-3" />
    </>
  ),
  message: <path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H12l-4.5 4v-4h-1A2.5 2.5 0 0 1 4 13.5z" />,
  email: (
    <>
      <rect x="3.5" y="5.5" width="17" height="13" rx="2" />
      <path d="M4.5 7.5l7.5 6 7.5-6" />
    </>
  ),
  other: (
    <>
      <path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H12l-4.5 4v-4h-1A2.5 2.5 0 0 1 4 13.5z" />
      <circle cx="8.5" cy="10" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="12" cy="10" r="0.9" fill="currentColor" stroke="none" />
      <circle cx="15.5" cy="10" r="0.9" fill="currentColor" stroke="none" />
    </>
  ),
  bell: (
    <>
      <path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2.5h-15z" />
      <path d="M10 20.5a2 2 0 0 0 4 0" />
    </>
  ),
  chevron: <path d="M9 5.5l6.5 6.5L9 18.5" />,
  back: <path d="M15 5.5L8.5 12l6.5 6.5" />,
  sparkle: (
    <path d="M12 4l1.7 4.6L18.5 10l-4.8 1.4L12 16l-1.7-4.6L5.5 10l4.8-1.4zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z" />
  ),
  heart: <path d="M12 19.5s-7-4.5-7-9.4C5 7.3 7 5.5 9.2 5.5c1.3 0 2.3.7 2.8 1.6.5-.9 1.5-1.6 2.8-1.6C17 5.5 19 7.3 19 10.1c0 4.9-7 9.4-7 9.4z" />,
  pencil: <path d="M14.5 5.5l4 4L8 20H4v-4zM13 7l4 4" />,
  x: <path d="M6 6l12 12M18 6L6 18" />,
  search: (
    <>
      <circle cx="11" cy="11" r="6.5" />
      <path d="M20 20l-4.2-4.2" />
    </>
  ),
  'chevron-down': <path d="M5.5 9l6.5 6.5L18.5 9" />,
  'chevron-right': <path d="M9 5.5l6.5 6.5L9 18.5" />,
  calendar: (
    <>
      <rect x="4" y="5.5" width="16" height="14.5" rx="2" />
      <path d="M4 10h16M8.5 3.5v4M15.5 3.5v4" />
    </>
  ),
  filter: <path d="M4 6h16M7 12h10M10 18h4" />,
  'arrow-right': <path d="M5 12h14M13 6l6 6-6 6" />,
  folder: <path d="M4 7.5A1.5 1.5 0 0 1 5.5 6h3.2a1.5 1.5 0 0 1 1.2.6l1 1.4h7.6A1.5 1.5 0 0 1 20 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z" />,
  project: (
    <>
      <path d="M4.5 6.5A1.5 1.5 0 0 1 6 5h12a1.5 1.5 0 0 1 1.5 1.5v11A1.5 1.5 0 0 1 18 19H6a1.5 1.5 0 0 1-1.5-1.5z" />
      <path d="M8 9.5h8M8 13h8M8 16.5h4" />
    </>
  ),
  trash: <path d="M5 7h14M10 7V5.5A1.5 1.5 0 0 1 11.5 4h1A1.5 1.5 0 0 1 14 5.5V7m-7 0 .8 11.1A1.5 1.5 0 0 0 9.3 19.5h5.4a1.5 1.5 0 0 0 1.5-1.4L17 7" />,
}

export type IconName = keyof typeof PATHS extends string ? string : never

export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  const path = PATHS[name] ?? PATHS.circle
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {path}
    </svg>
  )
}
