import { useParams } from 'react-router-dom'

export function PersonPage() {
  const { personID } = useParams()
  return (
    <main className="page">
      <h1 className="page-title">Person</h1>
      <p className="row-subtitle">Record {personID} — the portrait lands in a later step.</p>
    </main>
  )
}
