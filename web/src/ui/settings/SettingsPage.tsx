import { useState } from 'react'
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

export function SettingsPage() {
  const [keyDraft, setKeyDraft] = useState('')
  const [model, setModelState] = useState(storedModel())
  const [ready, setReady] = useState(aiCaptureReady())

  function saveKey() {
    if (!keyDraft.trim()) return
    setAPIKey(keyDraft)
    setKeyDraft('')
    setReady(true)
  }

  function forgetKey() {
    clearAPIKey()
    setReady(false)
  }

  return (
    <main className="page">
      <h1 className="page-title">Settings</h1>

      <h2 className="section-header">AI capture</h2>
      <p className="row-subtitle">
        Link your own Anthropic API key and dictated updates are parsed into
        interactions, facts, and follow-ups — always shown for review before
        anything is written. The key stays in this browser's local storage and
        is sent only to api.anthropic.com; your dictation and your people's
        names go along with each request, under your key.
      </p>

      {ready ? (
        <div style={{ margin: 'var(--space-medium) 0' }}>
          <p className="row-title">Key linked — AI capture is on.</p>
          <button
            type="button"
            className="button button-destructive"
            style={{ paddingLeft: 0 }}
            onClick={forgetKey}
          >
            Forget this key
          </button>
        </div>
      ) : (
        <>
          <label className="field-label" htmlFor="ai-key">
            Anthropic API key
          </label>
          <div style={{ display: 'flex', gap: 'var(--space-small)' }}>
            <input
              id="ai-key"
              className="field"
              type="password"
              value={keyDraft}
              onChange={(event) => setKeyDraft(event.target.value)}
              placeholder="sk-ant-…"
              autoComplete="off"
            />
            <button type="button" className="button" disabled={!keyDraft.trim()} onClick={saveKey}>
              Link
            </button>
          </div>
        </>
      )}

      <label className="field-label" htmlFor="ai-model">
        Model — your key, your cost call
      </label>
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
