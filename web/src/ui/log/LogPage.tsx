import { EmptyState } from '../components/EmptyState'

export function LogPage() {
  return (
    <main className="page">
      <h1 className="page-title">Log an interaction</h1>
      <EmptyState
        icon="pencil"
        headline="Composer coming"
        message="The interaction composer lands in a later step."
      />
    </main>
  )
}
