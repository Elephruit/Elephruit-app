import { describe, expect, it } from 'vitest'
import {
  ATTACHMENT_LIMITS,
  acceptList,
  attachmentsReadyForReview,
  isDuplicate,
  isLikelyScanned,
  kindForExtension,
  mimeMatchesExtension,
  validateSelection,
  type CaptureAttachment,
} from './attachments'

function fakeAttachment(overrides: Partial<CaptureAttachment>): CaptureAttachment {
  return {
    id: 'a1',
    file: null as unknown as File,
    name: 'dossier.pdf',
    detectedMimeType: 'application/pdf',
    kind: 'pdf',
    byteSize: 1000,
    sha256: null,
    status: 'ready',
    pageCount: 3,
    extractedText: 'text',
    requiresVision: false,
    errorCode: null,
    errorMessage: null,
    ...overrides,
  }
}

describe('type acceptance', () => {
  it('accepts exactly the first-pass formats and rejects the excluded ones', () => {
    for (const name of ['a.pdf', 'b.docx', 'c.txt', 'd.md', 'e.markdown', 'f.csv', 'g.tsv', 'h.png', 'i.jpg', 'j.jpeg', 'k.webp']) {
      expect(kindForExtension(name), name).not.toBeNull()
    }
    for (const name of ['a.doc', 'b.rtf', 'c.zip', 'd.rar', 'e.7z', 'f.exe', 'g.sh', 'h.mp3', 'i.mov', 'j']) {
      expect(kindForExtension(name), name).toBeNull()
    }
  })

  it('requires the sniffed type to match the extension', () => {
    expect(mimeMatchesExtension('report.pdf', 'application/pdf')).toBe(true)
    // A renamed binary must not ride in on a friendly extension.
    expect(mimeMatchesExtension('report.pdf', 'image/png')).toBe(false)
    expect(mimeMatchesExtension('notes.csv', 'text/csv')).toBe(true)
    expect(mimeMatchesExtension('notes.csv', 'text/plain')).toBe(true)
  })

  it('derives the picker accept list from the same rules', () => {
    const list = acceptList()
    expect(list).toContain('.pdf')
    expect(list).toContain('.webp')
    expect(list).not.toContain('.doc,')
  })
})

describe('selection limits', () => {
  it('rejects oversized files with the exact limit in the message', () => {
    const verdict = validateSelection({ name: 'big.pdf', byteSize: ATTACHMENT_LIMITS.maxFileBytes + 1 }, [])
    expect(verdict.ok).toBe(false)
    if (!verdict.ok) expect(verdict.message).toContain('20.0 MB')
  })

  it('enforces the file count and the total budget', () => {
    const many = Array.from({ length: ATTACHMENT_LIMITS.maxFiles }, (_, i) => ({ name: `f${i}.txt`, byteSize: 10 }))
    expect(validateSelection({ name: 'one-more.txt', byteSize: 10 }, many).ok).toBe(false)

    const heavy = [{ name: 'a.pdf', byteSize: 19 * 1024 * 1024 }, { name: 'b.pdf', byteSize: 19 * 1024 * 1024 }]
    expect(validateSelection({ name: 'c.pdf', byteSize: 19 * 1024 * 1024 }, heavy).ok).toBe(false)
  })
})

describe('duplicates and readiness', () => {
  it('prefers hashes and falls back to name+size+mtime', () => {
    expect(
      isDuplicate({ name: 'x.pdf', byteSize: 5, sha256: 'abc' }, [{ name: 'renamed.pdf', byteSize: 9, sha256: 'abc' }]),
    ).toBe(true)
    expect(
      isDuplicate({ name: 'x.pdf', byteSize: 5, lastModified: 1 }, [{ name: 'x.pdf', byteSize: 5, lastModified: 1 }]),
    ).toBe(true)
    expect(
      isDuplicate({ name: 'x.pdf', byteSize: 5, lastModified: 2 }, [{ name: 'x.pdf', byteSize: 5, lastModified: 1 }]),
    ).toBe(false)
  })

  it('marks a mostly-empty text layer as likely scanned', () => {
    expect(isLikelyScanned([10, 0, 20, 4000])).toBe(true)
    expect(isLikelyScanned([900, 1200, 40])).toBe(false)
    expect(isLikelyScanned([])).toBe(true)
  })

  it('blocks review while anything is extracting or errored', () => {
    expect(attachmentsReadyForReview([fakeAttachment({})])).toBe(true)
    expect(attachmentsReadyForReview([fakeAttachment({ status: 'extracting' })])).toBe(false)
    expect(attachmentsReadyForReview([fakeAttachment({ status: 'error' })])).toBe(false)
    expect(attachmentsReadyForReview([fakeAttachment({ status: 'excluded' })])).toBe(true)
    expect(attachmentsReadyForReview([])).toBe(true)
  })
})
