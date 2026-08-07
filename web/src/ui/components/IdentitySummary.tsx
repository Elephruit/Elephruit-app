/// A primary label with up to a few distinguishing details — "Son · Age 13 ·
/// 8th grade". The visual half of the relationship-identity work: the domain
/// half (relationshipIdentitySummary) chooses the details, this renders them
/// with an unambiguous accessible label instead of dot-separated soup for
/// screen readers.

export function IdentitySummary({
  primary,
  details = [],
  accessibleLabel,
}: {
  primary: React.ReactNode
  details?: string[]
  /// Full-sentence reading for assistive tech; falls back to visible text.
  accessibleLabel?: string
}) {
  return (
    <span className="identity-summary" aria-label={accessibleLabel}>
      <span className="identity-summary-primary">{primary}</span>
      {details.length > 0 && (
        <span className="identity-summary-details" aria-hidden={accessibleLabel ? true : undefined}>
          {details.join(' · ')}
        </span>
      )}
    </span>
  )
}
