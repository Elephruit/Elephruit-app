import { Link } from 'react-router-dom'

export function NotFound() {
  return (
    <main className="page-scaffold" data-width="narrow">
      <div className="error-panel">
        <h1>There is no page here</h1>
        <p>The address doesn't match anything in Elephruit.</p>
        <Link className="button" to="/">
          Back to the feed
        </Link>
      </div>
    </main>
  )
}
