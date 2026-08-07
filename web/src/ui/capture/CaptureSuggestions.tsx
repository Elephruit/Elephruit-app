/// Example captures, shown only while the composer is empty — one tap fills
/// the textarea so the first capture never starts from a blank page.

const EXAMPLES = [
  'Coffee with Ana. Her son starts at South High this fall. Need to send her the neighborhood list.',
  'Called Marisol about the co-op vote — she is leaning yes. Follow up Friday.',
  "Met Jonas's partner Elke at the gallery. She teaches printmaking in Oakland.",
]

export function CaptureSuggestions({ onPick }: { onPick: (example: string) => void }) {
  return (
    <div className="capture-examples">
      <span>Try</span>
      {EXAMPLES.map((example) => (
        <button key={example} type="button" className="chip" onClick={() => onPick(example)}>
          {example.split('.')[0]}…
        </button>
      ))}
    </div>
  )
}
