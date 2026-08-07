import { createContext, useContext } from 'react'

/// The signed-in user's uid, available everywhere below the auth gate. Pages
/// never see Firebase's User object — they only need the key their data lives under.
const UIDContext = createContext<string | null>(null)

export function UIDProvider({ uid, children }: { uid: string; children: React.ReactNode }) {
  return <UIDContext.Provider value={uid}>{children}</UIDContext.Provider>
}

export function useUID(): string {
  const uid = useContext(UIDContext)
  if (uid === null) {
    throw new Error('useUID called outside the signed-in shell.')
  }
  return uid
}
