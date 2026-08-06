/// Keeps a crashing page from taking the shell down with it: the rail stays
/// alive, the content column explains itself, and reload starts clean.

import { Component, type ReactNode } from 'react'

interface Props {
  children: ReactNode
}

interface State {
  error: Error | null
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  render() {
    if (this.state.error === null) return this.props.children
    return (
      <main className="page-scaffold" data-width="narrow">
        <div className="error-panel" role="alert">
          <h1>Something broke on this page</h1>
          <p>The rest of the app is fine. Reloading usually clears it; nothing you saved is lost.</p>
          <p className="error-panel-detail">{this.state.error.message}</p>
          <button className="button" onClick={() => window.location.reload()}>
            Reload
          </button>
        </div>
      </main>
    )
  }
}
