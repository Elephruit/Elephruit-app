/// Loading that looks intentional: shimmer bars where content is about to be.
/// The global reduced-motion switch stills the shimmer.

export function Skeleton({ width = '100%', height = 14 }: { width?: number | string; height?: number }) {
  return <span className="skeleton" style={{ width, height }} aria-hidden="true" />
}

export function SkeletonRows({ count = 6, avatar = false }: { count?: number; avatar?: boolean }) {
  return (
    <div className="skeleton-rows" role="status" aria-label="Loading">
      {Array.from({ length: count }, (_, index) => (
        <div key={index} className="skeleton-row">
          {avatar && <span className="skeleton skeleton-circle" />}
          <span className="skeleton-row-lines">
            <Skeleton width={`${55 + ((index * 17) % 30)}%`} />
            <Skeleton width={`${30 + ((index * 11) % 25)}%`} height={11} />
          </span>
        </div>
      ))}
    </div>
  )
}
