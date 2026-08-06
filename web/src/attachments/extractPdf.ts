/// PDF text extraction via pdf.js (pinned in package.json). The library is
/// dynamically imported so the main bundle stays lean, and it does its
/// parsing inside its own dedicated worker — the composer thread never
/// touches PDF internals. Scripts, embedded objects, and remote resources are
/// never evaluated: only the text content stream is read.

import { isLikelyScanned } from '../domain/attachments'

export class PdfPasswordError extends Error {}
export class PdfPageLimitError extends Error {
  readonly pageCount: number
  constructor(pageCount: number) {
    super(`PDF has ${pageCount} pages`)
    this.pageCount = pageCount
  }
}

export interface PdfExtraction {
  text: string
  pageCount: number
  requiresVision: boolean
}

export async function extractPdf(file: File, maxPages: number, signal?: AbortSignal): Promise<PdfExtraction> {
  const pdfjs = await import('pdfjs-dist')
  pdfjs.GlobalWorkerOptions.workerSrc = new URL('pdfjs-dist/build/pdf.worker.min.mjs', import.meta.url).toString()

  const data = await file.arrayBuffer()
  let document
  try {
    document = await pdfjs.getDocument({
      data,
      isEvalSupported: false,
      disableFontFace: true,
      useSystemFonts: false,
    }).promise
  } catch (cause) {
    if ((cause as { name?: string })?.name === 'PasswordException') throw new PdfPasswordError()
    throw cause
  }

  try {
    if (document.numPages > maxPages) throw new PdfPageLimitError(document.numPages)

    const pages: string[] = []
    const charCounts: number[] = []
    for (let index = 1; index <= document.numPages; index++) {
      if (signal?.aborted) throw new DOMException('Aborted', 'AbortError')
      const page = await document.getPage(index)
      const content = await page.getTextContent()
      const text = content.items
        .map((item) => ('str' in item ? item.str : ''))
        .join(' ')
        .replace(/\s+/g, ' ')
        .trim()
      charCounts.push(text.replace(/\s/g, '').length)
      // Page markers let extracted facts cite a page in review.
      pages.push(`[Page ${index}]\n${text}`)
    }

    return {
      text: pages.join('\n\n'),
      pageCount: document.numPages,
      requiresVision: isLikelyScanned(charCounts),
    }
  } finally {
    await document.destroy()
  }
}
