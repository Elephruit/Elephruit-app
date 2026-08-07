import { useState } from 'react'
import { FirebaseError } from 'firebase/app'
import { usingEmulators } from '../data/firebase'
import { signInAsLocalDevAccount, signInWithGoogle } from '../data/auth'
import { Button } from './components/Button'
import { Icon } from './components/Icon'

const REASSURANCES = [
  'Your records live in your own account, nowhere else.',
  'AI runs only under your own key, and only when you ask.',
  'Nothing is ever written without your review.',
]

function friendlyMessage(cause: unknown): { message: string; detail: string | null } {
  if (cause instanceof FirebaseError) {
    switch (cause.code) {
      case 'auth/popup-blocked':
        return { message: 'The browser blocked the sign-in window. Allow popups for this site and try again.', detail: null }
      case 'auth/popup-closed-by-user':
      case 'auth/cancelled-popup-request':
        return { message: 'The sign-in window closed before finishing. Try again when ready.', detail: null }
      case 'auth/network-request-failed':
        return { message: 'Could not reach the sign-in service. Check the connection and try again.', detail: null }
      default:
        return { message: 'Sign-in failed.', detail: cause.message }
    }
  }
  return { message: 'Sign-in failed.', detail: cause instanceof Error ? cause.message : null }
}

export function SignInPage() {
  const [error, setError] = useState<{ message: string; detail: string | null } | null>(null)
  const [busy, setBusy] = useState<'google' | 'dev' | null>(null)

  async function attempt(which: 'google' | 'dev', signIn: () => Promise<void>) {
    setError(null)
    setBusy(which)
    try {
      await signIn()
    } catch (cause) {
      setError(friendlyMessage(cause))
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="signin-split">
      <aside className="signin-brand">
        <img src="/brand/elephruit-logo.png" alt="Elephruit" className="signin-logo" />
        <h1>A private memory for the people you keep up with.</h1>
        <ul>
          {REASSURANCES.map((line) => (
            <li key={line}>
              <Icon name="check" size={14} />
              {line}
            </li>
          ))}
        </ul>
      </aside>

      <main className="signin-auth">
        <div className="signin-auth-inner">
          <h2>Sign in</h2>
          <p>Interactions, relationships, facts, and the follow-ups you owe — one quiet place.</p>

          <Button
            variant="primary"
            loading={busy === 'google'}
            onClick={() => void attempt('google', signInWithGoogle)}
          >
            Continue with Google
          </Button>

          {error && (
            <div className="signin-error" role="alert">
              <p>{error.message}</p>
              {error.detail && <p className="signin-error-detail">{error.detail}</p>}
            </div>
          )}

          {usingEmulators && (
            <div className="dev-box">
              <p className="dev-box-label">Local development</p>
              <p>Running against the emulators — nothing leaves this machine, and the dev account skips the popup.</p>
              <Button variant="secondary" loading={busy === 'dev'} onClick={() => void attempt('dev', signInAsLocalDevAccount)}>
                Use the local dev account
              </Button>
            </div>
          )}
        </div>
      </main>
    </div>
  )
}
