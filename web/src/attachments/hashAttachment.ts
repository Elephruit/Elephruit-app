/// SHA-256 over the raw bytes — duplicate detection and, later, source
/// metadata. Runs in the attachment worker.

export async function hashBytes(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', buffer)
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}
