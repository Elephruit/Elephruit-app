import { EmptyState } from '../components/EmptyState'

export function PeopleListPage() {
  return (
    <main className="page">
      <h1 className="page-title">People</h1>
      <EmptyState
        icon="people"
        headline="Nobody recorded yet"
        message="Add the people you talk to; everything else hangs off them."
      />
    </main>
  )
}
