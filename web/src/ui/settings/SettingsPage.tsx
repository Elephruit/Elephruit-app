import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  addAiCredential,
  deleteAiCredential,
  replaceAiCredential,
  verifyAiCredential,
  type AiCredential,
} from '../../ai/credentials'
import { GatewayError, type AIProvider } from '../../ai/gateway'
import {
  DEFAULT_MODEL_BY_PROVIDER,
  clearLegacyAPIKey,
  legacyStoredAPIKey,
  modelsForProvider,
  setAISelection,
  storedAISelection,
} from '../../ai/settings'
import { signOutUser } from '../../data/auth'
import { usingEmulators } from '../../data/firebase'
import { useAiCredentials } from '../../data/hooks'
import { useUID } from '../UserContext'
import { useDeveloperAdmin } from '../developer/context'
import { Button } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { FormField } from '../components/FormField'
import { SegmentedControl } from '../components/SegmentedControl'
import { Skeleton } from '../components/Skeleton'
import { setThemePreference, themePreference, type ThemePreference } from '../theme'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'

const STATUS_CHIP: Record<AiCredential['status'], { className: string; label: string }> = {
  active: { className: 'chip chip-status-done', label: 'Key linked' },
  unverified: { className: 'chip chip-status-today', label: 'Unverified' },
  invalid: { className: 'chip chip-status-overdue', label: 'Needs attention' },
  revoked: { className: 'chip chip-status-overdue', label: 'Revoked' },
}

const PROVIDERS: Record<AIProvider, { name: string; keyLabel: string; placeholder: string; consoleName: string }> = {
  anthropic: { name: 'Anthropic', keyLabel: 'Anthropic API key', placeholder: 'sk-ant-…', consoleName: 'Anthropic console' },
  openai: { name: 'OpenAI', keyLabel: 'OpenAI API key', placeholder: 'sk-proj-…', consoleName: 'OpenAI dashboard' },
  google: { name: 'Google Gemini', keyLabel: 'Google API key', placeholder: 'AIza…', consoleName: 'Google AI Studio' },
}

export function SettingsPage() {
  const uid = useUID()
  const developerAdmin = useDeveloperAdmin()
  const credentials = useAiCredentials(uid)
  const [selection, setSelectionState] = useState(storedAISelection())
  const providerInfo = PROVIDERS[selection.provider]
  const credential = credentials?.find((item) => item.provider === selection.provider) ?? null

  const [keyDraft, setKeyDraft] = useState('')
  const [showKey, setShowKey] = useState(false)
  const [busy, setBusy] = useState<'link' | 'replace' | 'verify' | 'delete' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [replacing, setReplacing] = useState(false)
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const [legacyKey, setLegacyKey] = useState<string | null>(() => legacyStoredAPIKey())
  const [theme, setThemeState] = useState<ThemePreference>(themePreference())
  const keyInputRef = useRef<HTMLInputElement>(null)

  function beginAction(action: 'link' | 'replace' | 'verify' | 'delete') {
    setBusy(action)
    setError(null)
    setNotice(null)
  }

  function surface(cause: unknown, fallback: string) {
    setError(cause instanceof GatewayError ? cause.message : fallback)
  }

  async function linkKey(rawKey: string, options: { fromLegacy: boolean }) {
    if (!rawKey.trim() || busy) return
    beginAction('link')
    try {
      const provider = options.fromLegacy ? 'anthropic' : selection.provider
      const summary = await addAiCredential(provider, rawKey.trim())
      if (options.fromLegacy) {
        clearLegacyAPIKey()
        setLegacyKey(null)
      }
      setKeyDraft('')
      setShowKey(false)
      if (summary.status === 'unverified') {
        setNotice('Stored — but the provider could not be reached to check it yet. Verify once things settle.')
      }
    } catch (cause) {
      surface(cause, 'Something went wrong. The key was not saved.')
    } finally {
      setBusy(null)
    }
  }

  async function replaceKey() {
    if (!credential || !keyDraft.trim() || busy) return
    beginAction('replace')
    try {
      await replaceAiCredential(credential.id, keyDraft.trim())
      setKeyDraft('')
      setShowKey(false)
      setReplacing(false)
    } catch (cause) {
      surface(cause, 'Something went wrong. The existing key is untouched.')
    } finally {
      setBusy(null)
    }
  }

  async function verifyNow() {
    if (!credential || busy) return
    beginAction('verify')
    try {
      const result = await verifyAiCredential(credential.id)
      if (result.outcome === 'inconclusive') {
        setNotice('The provider could not be reached — the key is unchanged. Try again in a moment.')
      }
    } catch (cause) {
      surface(cause, 'Verification did not complete. Nothing changed.')
    } finally {
      setBusy(null)
    }
  }

  async function removeCredential() {
    if (!credential || busy) return
    beginAction('delete')
    try {
      await deleteAiCredential(credential.id)
      setConfirmingDelete(false)
      setReplacing(false)
    } catch (cause) {
      surface(cause, 'Something went wrong. The credential is untouched.')
    } finally {
      setBusy(null)
    }
  }

  const headChip = credential ? STATUS_CHIP[credential.status] : null
  const migratableLegacyKey = selection.provider === 'anthropic' ? legacyKey : null
  const showAddForm = credentials !== undefined && !credential && !migratableLegacyKey
  const showKeyInput = showAddForm || (credential !== null && replacing)

  return (
    <PageScaffold width="narrow">
      <PageHeader title="Settings" />

      {developerAdmin && (
        <section className="settings-panel aside-panel">
          <div className="aside-panel-head">
            <h2 className="aside-title">Developer</h2>
          </div>
          <p className="settings-help">Review unknown AI taxonomy values reported by capture normalization.</p>
          <Link className="inline-link" to="/developer">Open developer view</Link>
        </section>
      )}

      <section className="settings-panel aside-panel">
        <div className="aside-panel-head">
          <h2 className="aside-title">AI</h2>
          {headChip && <span className={headChip.className}>{headChip.label}</span>}
        </div>
        <p className="settings-help">
          Your own provider key, in both directions: dictated updates parsed into interactions, facts, and
          follow-ups — always reviewed before anything is written — and briefs that prepare you for the people
          you're seeing. When you link it, the key is encrypted and kept server-side; each request you start
          decrypts it there just long enough to call your selected provider. It is never shown again and never returns to this
          browser. Restricted facts never enter any request.
        </p>

        <FormField label="Provider" htmlFor="ai-provider">
          <select
            id="ai-provider"
            className="field"
            value={selection.provider}
            onChange={(event) => {
              const provider = event.target.value as AIProvider
              const next = { provider, model: DEFAULT_MODEL_BY_PROVIDER[provider] }
              setSelectionState(next)
              setAISelection(next)
              setReplacing(false)
              setKeyDraft('')
              setError(null)
              setNotice(null)
            }}
          >
            <option value="anthropic">Anthropic</option>
            <option value="openai">OpenAI</option>
            <option value="google">Google Gemini</option>
          </select>
        </FormField>

        {credentials === undefined && (
          <div className="settings-key-row">
            <Skeleton width="60%" />
          </div>
        )}

        {credentials !== undefined && !credential && migratableLegacyKey && (
          <div className="callout callout-stacked">
            <p>
              A key from the earlier version of this app is still stored in this browser. Link it to your account —
              it will be encrypted server-side and removed from this browser — or discard it here. Nothing moves
              without your say-so.
            </p>
            <span className="settings-key-actions">
              <Button variant="primary" small loading={busy === 'link'} onClick={() => void linkKey(migratableLegacyKey, { fromLegacy: true })}>
                Link this key
              </Button>
              <Button
                variant="ghost"
                small
                onClick={() => {
                  clearLegacyAPIKey()
                  setLegacyKey(null)
                }}
              >
                Discard it
              </Button>
            </span>
          </div>
        )}

        {selection.provider === 'anthropic' && credential && legacyKey && (
          <div className="callout callout-stacked">
            <p>
              An old copy of a key is still in this browser's local storage. Your credential now lives server-side,
              so the local copy is unused — remove it.
            </p>
            <span className="settings-key-actions">
              <Button
                variant="secondary"
                small
                onClick={() => {
                  clearLegacyAPIKey()
                  setLegacyKey(null)
                }}
              >
                Remove local copy
              </Button>
            </span>
          </div>
        )}

        {credential && !replacing && (
          <div className="settings-key-row">
            <span className="row-subtitle">••••…{credential.keyHint}</span>
            <span className="settings-key-actions">
              {credential.status !== 'active' && (
                <Button variant="secondary" small loading={busy === 'verify'} onClick={() => void verifyNow()}>
                  Verify
                </Button>
              )}
              <Button
                variant="ghost"
                small
                onClick={() => {
                  setReplacing(true)
                  setError(null)
                  setNotice(null)
                  setTimeout(() => keyInputRef.current?.focus(), 0)
                }}
              >
                Replace
              </Button>
              <Button variant="destructive" small onClick={() => setConfirmingDelete(true)}>
                Remove
              </Button>
            </span>
          </div>
        )}

        {credential?.status === 'invalid' && !replacing && (
          <p className="settings-help">
            The provider stopped accepting this key. Replace it, or verify again after fixing it in the{' '}
            {providerInfo.consoleName}.
          </p>
        )}

        {showKeyInput && (
          <FormField label={replacing ? `New ${providerInfo.keyLabel}` : providerInfo.keyLabel} htmlFor="ai-key">
            <div className="settings-key-input">
              <input
                ref={keyInputRef}
                id="ai-key"
                className="field"
                type={showKey ? 'text' : 'password'}
                value={keyDraft}
                onChange={(event) => setKeyDraft(event.target.value)}
                placeholder={providerInfo.placeholder}
                autoComplete="off"
                spellCheck={false}
              />
              <Button variant="ghost" small onClick={() => setShowKey((current) => !current)}>
                {showKey ? 'Hide' : 'Show'}
              </Button>
              {replacing ? (
                <>
                  <Button
                    variant="ghost"
                    small
                    onClick={() => {
                      setReplacing(false)
                      setKeyDraft('')
                    }}
                  >
                    Cancel
                  </Button>
                  <Button
                    variant="primary"
                    disabled={!keyDraft.trim()}
                    loading={busy === 'replace'}
                    onClick={() => void replaceKey()}
                  >
                    {busy === 'replace' ? 'Verifying…' : 'Replace'}
                  </Button>
                </>
              ) : (
                <Button
                  variant="primary"
                  disabled={!keyDraft.trim()}
                  loading={busy === 'link'}
                  onClick={() => void linkKey(keyDraft, { fromLegacy: false })}
                >
                  {busy === 'link' ? 'Verifying…' : 'Link'}
                </Button>
              )}
            </div>
          </FormField>
        )}

        {error && (
          <p className="field-error" role="alert">
            {error}
          </p>
        )}
        {notice && <p className="field-help">{notice}</p>}

        <FormField label="Model — your key, your cost call" htmlFor="ai-model">
          <select
            id="ai-model"
            className="field"
            value={selection.model}
            onChange={(event) => {
              const next = { ...selection, model: event.target.value }
              setSelectionState(next)
              setAISelection(next)
            }}
          >
            {modelsForProvider(selection.provider).map((choice) => (
              <option key={choice.id} value={choice.id}>
                {choice.label}
              </option>
            ))}
          </select>
        </FormField>
      </section>

      <section className="settings-panel aside-panel">
        <div className="aside-panel-head">
          <h2 className="aside-title">Appearance</h2>
        </div>
        <p className="settings-help">System follows the OS; the choice is remembered in this browser.</p>
        <SegmentedControl
          label="Appearance"
          options={[
            { value: 'system', label: 'System' },
            { value: 'light', label: 'Light' },
            { value: 'dark', label: 'Dark' },
          ]}
          value={theme}
          onChange={(next) => {
            setThemeState(next)
            setThemePreference(next)
          }}
        />
      </section>

      <section className="settings-panel aside-panel">
        <div className="aside-panel-head">
          <h2 className="aside-title">Account</h2>
        </div>
        <p className="settings-help">
          {usingEmulators
            ? 'Signed in against the local emulators. Nothing leaves this machine.'
            : 'Signed in with Google.'}
        </p>
        <div>
          <Button variant="secondary" onClick={() => void signOutUser()}>
            Sign out
          </Button>
        </div>
      </section>

      {confirmingDelete && credential && (
        <Dialog title="Remove this credential?" onClose={() => setConfirmingDelete(false)}>
          <p>
            AI features stop working until you link another key. Removing it here deletes the encrypted copy on our
            side but does not revoke the key at {providerInfo.name} — do that in the {providerInfo.consoleName} if the key itself is
            compromised.
          </p>
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setConfirmingDelete(false)}>
              Keep it
            </Button>
            <Button variant="destructive" loading={busy === 'delete'} onClick={() => void removeCredential()}>
              Remove credential
            </Button>
          </div>
        </Dialog>
      )}
    </PageScaffold>
  )
}
