/// DOCX extraction runs inside the attachment worker (see
/// attachment.worker.ts) via mammoth's raw-text path: paragraphs and table
/// cells come out as text, macros and embedded objects are never executed,
/// and hyperlink targets are never followed.

import mammoth from 'mammoth'

export interface DocxExtraction {
  text: string
}

export async function extractDocx(buffer: ArrayBuffer): Promise<DocxExtraction> {
  const result = await mammoth.extractRawText({ arrayBuffer: buffer })
  // Normalize the paragraph stream: mammoth separates blocks with \n\n;
  // table rows arrive as consecutive cell paragraphs, kept line-per-cell —
  // stable, if plain. Collapse runs of blank lines.
  const text = result.value.replace(/\n{3,}/g, '\n\n').trim()
  return { text }
}
