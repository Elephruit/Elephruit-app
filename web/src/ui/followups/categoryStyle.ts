const CATEGORY_COLORS = ['blue', 'mint', 'purple', 'orange', 'teal', 'pink', 'indigo', 'green'] as const

export const DEFAULT_FOLLOWUP_CATEGORIES = ['Work', 'Personal', 'Waiting', 'Important'] as const

function folded(value: string): string {
  return value.trim().toLocaleLowerCase()
}

export function categoryTintStyle(tag: string): React.CSSProperties {
  let hash = 0
  for (const character of folded(tag)) hash = (hash * 31 + character.charCodeAt(0)) | 0
  const color = CATEGORY_COLORS[Math.abs(hash) % CATEGORY_COLORS.length]
  return { '--category-tint': `var(--palette-${color})` } as React.CSSProperties
}
