import {
  GoogleAuthProvider,
  onAuthStateChanged,
  signInWithPopup,
  signOut,
  type User,
} from 'firebase/auth'
import { useEffect, useState } from 'react'
import { auth } from './firebase'

export async function signInWithGoogle(): Promise<void> {
  await signInWithPopup(auth, new GoogleAuthProvider())
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
