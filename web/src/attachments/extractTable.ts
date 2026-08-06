/// CSV/TSV: decoded as UTF-8 with row and column boundaries preserved in a
/// stable plain-text form — one line per row, cells joined with ' | ' so the
/// model can cite "row 12" and the user can recognize it.

export async function extractTable(file: File, delimiter: ',' | '\t'): Promise<string> {
  const raw = new TextDecoder('utf-8').decode(await file.arrayBuffer())
  const rows = parseDelimited(raw, delimiter)
  return rows.map((cells, index) => `[Row ${index + 1}] ${cells.join(' | ')}`).join('\n')
}

/// A small RFC-4180-ish parser: quoted cells may contain delimiters, quotes
/// double-escape, newlines split records outside quotes.
export function parseDelimited(text: string, delimiter: ',' | '\t'): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false

  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (quoted) {
      if (char === '"') {
        if (text[i + 1] === '"') {
          cell += '"'
          i++
        } else {
          quoted = false
        }
      } else {
        cell += char
      }
    } else if (char === '"' && cell === '') {
      quoted = true
    } else if (char === delimiter) {
      row.push(cell)
      cell = ''
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') i++
      row.push(cell)
      cell = ''
      if (row.some((c) => c.length > 0)) rows.push(row)
      row = []
    } else {
      cell += char
    }
  }
  row.push(cell)
  if (row.some((c) => c.length > 0)) rows.push(row)
  return rows
}
