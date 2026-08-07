/// Images are re-encoded before they may travel: orientation applied, longest
/// edge capped, EXIF and every other metadata block gone by construction —
/// a canvas re-encode carries pixels only. Runs in the attachment worker via
/// OffscreenCanvas.

const MAX_EDGE = 1568

export interface PreparedImage {
  bytes: ArrayBuffer
  mimeType: 'image/jpeg' | 'image/png'
}

export async function prepareImage(buffer: ArrayBuffer, sourceMime: string): Promise<PreparedImage> {
  const bitmap = await createImageBitmap(new Blob([buffer], { type: sourceMime }), {
    imageOrientation: 'from-image',
  })
  try {
    const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height))
    const width = Math.max(1, Math.round(bitmap.width * scale))
    const height = Math.max(1, Math.round(bitmap.height * scale))

    const canvas = new OffscreenCanvas(width, height)
    const context = canvas.getContext('2d')
    if (!context) throw new Error('No 2d context for image re-encode')
    context.drawImage(bitmap, 0, 0, width, height)

    // PNG keeps line art crisp; everything else compresses well as JPEG.
    const mimeType = sourceMime === 'image/png' ? 'image/png' : 'image/jpeg'
    const blob = await canvas.convertToBlob({ type: mimeType, quality: 0.85 })
    return { bytes: await blob.arrayBuffer(), mimeType: mimeType as PreparedImage['mimeType'] }
  } finally {
    bitmap.close()
  }
}
