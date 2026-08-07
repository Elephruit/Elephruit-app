export function categoryKey(tag: string): string {
  return tag.trim().toLocaleLowerCase()
}

/// Category identity is case-insensitive, while the first spelling remains the
/// display spelling. Existing user-authored casing therefore wins over starter
/// suggestions without allowing Work/work to become separate categories.
export function uniqueCategoryTags(tags: Iterable<string>): string[] {
  const seen = new Set<string>()
  const unique: string[] = []
  for (const rawTag of tags) {
    const tag = rawTag.trim()
    const key = categoryKey(tag)
    if (!key || seen.has(key)) continue
    seen.add(key)
    unique.push(tag)
  }
  return unique
}
