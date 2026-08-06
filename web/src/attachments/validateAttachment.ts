/// Content sniffing: the detected MIME type comes from magic bytes, never
/// from the file's self-declared type, and it must match the extension. Text
/// formats have no magic — they must decode as UTF-8 with no NUL bytes.

export async function sniffMimeType(file: File): Promise<string | null> {
  const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())

  const startsWith = (bytes: number[]) => bytes.every((byte, index) => head[index] === byte)

  if (startsWith([0x25, 0x50, 0x44, 0x46, 0x2d])) return 'application/pdf' // %PDF-
  if (startsWith([0x50, 0x4b, 0x03, 0x04])) {
    // ZIP container — a .docx is one; the extension check decides whether we
    // treat it as Word. Raw .zip is rejected by extension anyway.
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  }
  if (startsWith([0x89, 0x50, 0x4e, 0x47])) return 'image/png'
  if (startsWith([0xff, 0xd8, 0xff])) return 'image/jpeg'
  if (
    startsWith([0x52, 0x49, 0x46, 0x46]) &&
    head[8] === 0x57 &&
    head[9] === 0x45 &&
    head[10] === 0x42 &&
    head[11] === 0x50
  )
    return 'image/webp' // RIFF....WEBP

  // Plausibly text: sample the head, require valid UTF-8 and no NULs.
  const sample = new Uint8Array(await file.slice(0, 8192).arrayBuffer())
  if (sample.some((byte) => byte === 0)) return null
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(sample)
  } catch {
    return null
  }
  const extension = file.name.slice(file.name.lastIndexOf('.') + 1).toLowerCase()
  if (extension === 'csv') return 'text/csv'
  if (extension === 'tsv') return 'text/tab-separated-values'
  if (extension === 'md' || extension === 'markdown') return 'text/markdown'
  return 'text/plain'
}
