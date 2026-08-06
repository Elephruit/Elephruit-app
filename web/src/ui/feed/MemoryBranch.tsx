/// The one-pixel lateral from the rail to a moment's content, tinted quietly
/// by the moment's character. Purely presentational; geometry comes from the
/// shared tokens.

export function MemoryBranch({ tint }: { tint?: string }) {
  return (
    <span
      className="memory-branch-line"
      aria-hidden="true"
      style={tint ? ({ '--branch-tint': tint } as React.CSSProperties) : undefined}
    />
  )
}
