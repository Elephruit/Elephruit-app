import { EmptyState } from '../components/EmptyState'

export function FeedPage() {
  return (
    <main className="page">
      <h1 className="page-title">Feed</h1>
      <EmptyState
        icon="feed"
        headline="Nothing logged yet"
        message="Interactions you log will read here as one continuous thread."
      />
    </main>
  )
}
