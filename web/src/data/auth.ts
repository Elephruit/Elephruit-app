import {
  GoogleAuthProvider,
  createUserWithEmailAndPassword,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut,
  type User,
} from 'firebase/auth'
import { useEffect, useState } from 'react'
import { auth, usingEmulators } from './firebase'

export async function signInWithGoogle(): Promise<void> {
  await signInWithPopup(auth, new GoogleAuthProvider())
}

/// Emulator-only: a popup-free sign-in so the local loop never depends on a
/// popup window (embedded browsers and phone popup blockers both eat them).
/// The auth emulator accepts email/password without any project configuration,
/// and the security rules only ever look at request.auth.uid.
export async function signInAsLocalDevAccount(): Promise<void> {
  if (!usingEmulators) {
    throw new Error('The local dev account exists only against the emulators.')
  }
  const email = 'dev@local.test'
  const password = 'local-dev-password'
  try {
    await signInWithEmailAndPassword(auth, email, password)
  } catch {
    await createUserWithEmailAndPassword(auth, email, password)
  }
}

export async function signOutUser(): Promise<void> {
  await signOut(auth)
}

export interface AuthState {
  user: User | null
  /// False until Firebase has restored (or denied) the session — the gate shows
  /// nothing rather than flashing the sign-in screen at a signed-in user.
  ready: boolean
}

export function useAuthUser(): AuthState {
  const [state, setState] = useState<AuthState>({ user: auth.currentUser, ready: false })

  useEffect(() => {
    return onAuthStateChanged(auth, (user) => setState({ user, ready: true }))
  }, [])

  return state
}
