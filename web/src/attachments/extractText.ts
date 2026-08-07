/// Plain text and Markdown: decode as UTF-8. Markup is formatting, not
/// instructions — the dossier prompt treats all extracted text as untrusted
/// source material, so nothing is stripped or interpreted here.

export async function extractText(file: File): Promise<string> {
  const buffer = await file.arrayBuffer()
  return new TextDecoder('utf-8').decode(buffer)
}
