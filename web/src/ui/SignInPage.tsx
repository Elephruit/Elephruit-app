import { useState } from 'react'
import { usingEmulators } from '../data/firebase'
import { signInAsLocalDevAccount, signInWithGoogle } from '../data/auth'

export function SignInPage() {
  const [error, setError] = useState<string | null>(null)

  async function attempt(signIn: () => Promise<void>) {
    setError(null)
    try {
      await signIn()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Sign-in failed.')
    }
  }

  return (
    <div className="signin">
      <h1>Elephruit</h1>
      <p>
        Log interactions with people, note relationships, keep facts, and track
        the follow-ups you owe them.
      </p>
      <button type="button" className="button" onClick={() => void attempt(signInWithGoogle)}>
        Sign in with Google
      </button>
      {usingEmulators && (
        <>
          <button
            type="button"
            className="button button-quiet"
            onClick={() => void attempt(signInAsLocalDevAccount)}
          >
            Use the local dev account
          </button>
          <p>
            Running against local emulators — nothing leaves this machine. The
            dev account skips the popup entirely.
          </p>
        </>
      )}
      {error && <p role="alert">{error}</p>}
    </div>
  )
}
