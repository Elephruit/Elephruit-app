import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  activeCredential,
  addAiCredential,
  deleteAiCredential,
  replaceAiCredential,
  verifyAiCredential,
  type AiCredential,
} from '../../ai/credentials'
import { GatewayError, type AIProvider } from '../../ai/gateway'
import {
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

const PROVIDER_OPTIONS: ReadonlyArray<{ value: AIProvider; label: string }> = [
  { value: 'anthropic', label: 'Anthropic' },
  { value: 'openai', label: 'OpenAI' },
  { value: 'google', label: 'Gemini' },
]

export function SettingsPage() {
  const uid = useUID()
  const developerAdmin = useDeveloperAdmin()
  const credentials = useAiCredentials(uid)
  const [selection, setSelectionState] = useState(storedAISelection())
  const [credentialProvider, setCredentialProvider] = useState<AIProvider>(selection.provider)
  const providerInfo = PROVIDERS[credentialProvider]
  const credential = credentials?.find((item) => item.provider === credentialProvider) ?? null

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
      const provider = options.fromLegacy ? 'anthropic' : credentialProvider
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
  const migratableLegacyKey = credentialProvider === 'anthropic' ? legacyKey : null
  const showAddForm = credentials !== undefined && !credential && !migratableLegacyKey
  const showKeyInput = showAddForm || (credential !== null && replacing)
  const selectedModel = modelsForProvider(selection.provider).find((model) => model.id === selection.model) ?? null
  const activeModel = activeCredential(credentials, selection.provider) ? selectedModel : null
  const keyProviderOptions = PROVIDER_OPTIONS.map((option) => ({
    ...option,
    label: activeCredential(credentials, option.value)
      ? `${option.label} ✓`
      : credentials?.some((item) => item.provider === option.value)
        ? `${option.label} !`
        : option.label,
  }))

  function showProviderKey(provider: AIProvider) {
    setCredentialProvider(provider)
    setReplacing(false)
    setKeyDraft('')
    setError(null)
    setNotice(null)
  }

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
        </div>
        <p className="settings-help">
          Your own provider key, in both directions: dictated updates parsed into interactions, facts, and
          follow-ups — always reviewed before anything is written — and briefs that prepare you for the people
          you're seeing. When you link it, the key is encrypted and kept server-side; each request you start
          decrypts it there just long enough to call your selected provider. It is never shown again and never returns to this
          browser. Restricted facts never enter any request.
        </p>

        <div className="ai-model-heading">
          <span className="field-label" id="active-model-label">Active model</span>
          {activeModel ? (
            <span className="ai-active-model-summary">
              {activeModel.shortLabel}
              <span>{PROVIDERS[activeModel.provider].name}</span>
            </span>
          ) : (
            <span className="ai-no-active-model">No active model</span>
          )}
        </div>
        <p className="field-help">
          {credentials === undefined
            ? 'Checking linked API keys…'
            : activeModel
              ? 'This is the one model used by capture, briefs, and talking points.'
              : 'Link an API key below, then choose one of that provider’s models.'}
        </p>

        <div className="ai-model-picker" role="radiogroup" aria-labelledby="active-model-label">
          {PROVIDER_OPTIONS.map((provider) => (
            <div className="ai-model-provider-row" key={provider.value}>
              <span className="ai-model-provider-name">{provider.label}</span>
              <div className="seg">
                {modelsForProvider(provider.value).map((model) => {
                  const providerReady = activeCredential(credentials, provider.value) !== null
                  const active = providerReady && model.id === selection.model
                  return (
                    <button
                      key={model.id}
                      type="button"
                      role="radio"
                      aria-checked={active}
                      disabled={!providerReady}
                      title={providerReady ? model.label : `Link a ${PROVIDERS[provider.value].name} API key first`}
                      onClick={() => {
                        const next = { provider: model.provider, model: model.id }
                        setSelectionState(next)
                        setAISelection(next)
                      }}
                    >
                      {model.shortLabel}
                      {active && <span className="ai-model-active-label">Active</span>}
                    </button>
                  )
                })}
              </div>
            </div>
          ))}
        </div>

        <div className="ai-key-settings">
          <div className="aside-panel-head">
            <h3 className="field-label">API keys</h3>
            {headChip && <span className={headChip.className}>{headChip.label}</span>}
          </div>
          <p className="field-help">Keep keys for every provider here, then switch the active model without re-entering them.</p>
          <div className="settings-segmented">
            <SegmentedControl
              label="Manage provider key"
              options={keyProviderOptions}
              value={credentialProvider}
              onChange={showProviderKey}
            />
          </div>
        </div>

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

        {credentialProvider === 'anthropic' && credential && legacyKey && (
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
