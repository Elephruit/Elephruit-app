import { useRef, useState } from 'react'
import {
  AI_MODELS,
  aiCaptureReady,
  clearAPIKey,
  setAPIKey,
  setModel,
  storedModel,
} from '../../ai/settings'
import { signOutUser } from '../../data/auth'
import { usingEmulators } from '../../data/firebase'
import { Button } from '../components/Button'
import { FormField } from '../components/FormField'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'

export function SettingsPage() {
  const [keyDraft, setKeyDraft] = useState('')
  const [showKey, setShowKey] = useState(false)
  const [model, setModelState] = useState(storedModel())
  const [ready, setReady] = useState(aiCaptureReady())
  const keyInputRef = useRef<HTMLInputElement>(null)

  function saveKey() {
    if (!keyDraft.trim()) return
    setAPIKey(keyDraft)
    setKeyDraft('')
    setShowKey(false)
    setReady(true)
  }

  function replaceKey() {
    clearAPIKey()
    setReady(false)
    setTimeout(() => keyInputRef.current?.focus(), 0)
  }

  return (
    <PageScaffold width="narrow">
      <PageHeader title="Settings" />

      <section className="settings-panel aside-panel">
        <div className="aside-panel-head">
          <h2 className="aside-title">AI</h2>
          {ready && <span className="chip chip-status-done">Key linked</span>}
        </div>
        <p className="settings-help">
          Your own Anthropic key, in both directions: dictated updates parsed into interactions, facts, and
          follow-ups — always reviewed before anything is written — and briefs that prepare you for the people
          you're seeing. The key lives in this browser's local storage and is sent only to api.anthropic.com.
          Restricted facts never leave this device.
        </p>

        {ready ? (
          <div className="settings-key-row">
            <span className="row-subtitle">sk-ant-••••••••</span>
            <span className="settings-key-actions">
              <Button variant="ghost" small onClick={replaceKey}>
                Replace
              </Button>
              <Button
                variant="destructive"
                small
                onClick={() => {
                  clearAPIKey()
                  setReady(false)
                }}
              >
                Remove
              </Button>
            </span>
          </div>
        ) : (
          <FormField label="Anthropic API key" htmlFor="ai-key">
            <div className="settings-key-input">
              <input
                ref={keyInputRef}
                id="ai-key"
                className="field"
                type={showKey ? 'text' : 'password'}
                value={keyDraft}
                onChange={(event) => setKeyDraft(event.target.value)}
                placeholder="sk-ant-…"
                autoComplete="off"
              />
              <Button variant="ghost" small onClick={() => setShowKey((s) => !s)}>
                {showKey ? 'Hide' : 'Show'}
              </Button>
              <Button variant="primary" disabled={!keyDraft.trim()} onClick={saveKey}>
                Link
              </Button>
            </div>
          </FormField>
        )}

        <FormField label="Model — your key, your cost call" htmlFor="ai-model">
          <select
            id="ai-model"
            className="field"
            value={model}
            onChange={(event) => {
              setModelState(event.target.value)
              setModel(event.target.value)
            }}
          >
            {AI_MODELS.map((choice) => (
              <option key={choice.id} value={choice.id}>
                {choice.label}
              </option>
            ))}
          </select>
        </FormField>
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
    </PageScaffold>
  )
}
