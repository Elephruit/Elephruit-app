import { useNavigate } from 'react-router-dom'

export function CapturePage() {
  const navigate = useNavigate()
  return (
    <main className="page">
      <h1 className="page-title">What happened?</h1>
      <p className="row-subtitle">
        Quick capture lands in a later step. For now, use the manual composer.
      </p>
      <div className="sheet-actions">
        <button type="button" className="button" onClick={() => navigate('/log')}>
          Log manually
        </button>
      </div>
    </main>
  )
}
