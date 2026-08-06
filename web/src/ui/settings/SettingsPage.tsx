import { signOutUser } from '../../data/auth'
import { usingEmulators } from '../../data/firebase'

export function SettingsPage() {
  return (
    <main className="page">
      <h1 className="page-title">Settings</h1>

      <h2 className="section-header">Account</h2>
      <p className="row-subtitle">
        {usingEmulators
          ? 'Signed in against the local emulators. Nothing leaves this machine.'
          : 'Signed in with Google.'}
      </p>
      <div style={{ marginTop: 'var(--space-medium)' }}>
        <button type="button" className="button button-quiet" onClick={() => void signOutUser()}>
          Sign out
        </button>
      </div>
    </main>
  )
}
