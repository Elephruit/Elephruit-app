/// Every document this app writes is keyed by a client-generated UUID, the same
/// identifier scheme the Mac app's archive format preserves on export — so a future
/// importer can carry records across without re-keying anything.
export const newID = (): string => crypto.randomUUID()
