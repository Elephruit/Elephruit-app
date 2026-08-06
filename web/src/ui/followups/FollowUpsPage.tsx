import { EmptyState } from '../components/EmptyState'

export function FollowUpsPage() {
  return (
    <main className="page">
      <h1 className="page-title">Follow-ups</h1>
      <EmptyState
        icon="bell"
        headline="Nothing owed"
        message="Follow-ups from logged interactions gather here, bucketed by what their dates actually say."
      />
    </main>
  )
}
