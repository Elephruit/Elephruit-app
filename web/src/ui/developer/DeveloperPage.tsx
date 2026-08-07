import { useCallback, useEffect, useState } from 'react'
import { listAiTaxonomyGaps, type TaxonomyGapSummary } from '../../ai/taxonomy'
import { Button } from '../components/Button'
import { Skeleton } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'

function dateTime(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Unknown' : date.toLocaleString()
}

export function DeveloperPage() {
  const [gaps, setGaps] = useState<TaxonomyGapSummary[] | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async () => {
    setRefreshing(true)
    setError(null)
    try {
      setGaps(await listAiTaxonomyGaps())
    } catch {
      setError('Could not load taxonomy reports. Confirm this account is the verified developer admin.')
    } finally {
      setRefreshing(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Developer"
        subtitle="AI taxonomy gaps reported during capture normalization"
        actions={<Button small loading={refreshing} onClick={() => void load()}>Refresh</Button>}
      />

      <section className="developer-panel aside-panel">
        <div className="aside-panel-head">
          <h2 className="aside-title">Unknown values</h2>
          {gaps && <span className="chip">{gaps.length} categories</span>}
        </div>
        <p className="settings-help">
          Reports contain only a bounded field name and taxonomy-shaped value. No user ID, person name, fact,
          or capture text is stored.
        </p>

        {error && <div className="callout callout-error" role="alert">{error}</div>}
        {gaps === undefined && !error && <div className="developer-loading"><Skeleton width="100%" /><Skeleton width="75%" /></div>}
        {gaps?.length === 0 && <p className="developer-empty">No taxonomy gaps have been reported.</p>}
        {gaps && gaps.length > 0 && (
          <div className="developer-table-wrap">
            <table className="developer-table">
              <thead>
                <tr><th>Field</th><th>Unknown value</th><th>Count</th><th>First seen</th><th>Last seen</th></tr>
              </thead>
              <tbody>
                {gaps.map((gap) => (
                  <tr key={gap.id}>
                    <td><code>{gap.field}</code></td>
                    <td><strong>{gap.value}</strong></td>
                    <td>{gap.count.toLocaleString()}</td>
                    <td>{dateTime(gap.firstSeenAt)}</td>
                    <td>{dateTime(gap.lastSeenAt)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </PageScaffold>
  )
}
