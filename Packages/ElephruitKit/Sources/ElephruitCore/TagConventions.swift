/// Tags the app itself understands.
///
/// Almost every tag in a library is the user's own word and means whatever they meant by it. A very
/// small number are read by the app as well — they decide which section a task appears under — and
/// those are the ones that have to be spelled the same way in the code that writes them, the code
/// that recognises them, and the code that hides them from a chip row. Left as string literals they
/// were spelled the same way in three files and differently in a fourth.
public enum TagConventions {
    /// Marks a task as something owed to somebody, rather than a job the user gave themselves.
    ///
    /// `follow-up` is the spelling the app writes and teaches. `promise` is still recognised because
    /// libraries written before the rename contain it, and quietly dropping those tasks out of the
    /// section they were filed under would be a loss the user could not see. Nothing writes `promise`
    /// any more, so the second spelling ages out of a library on its own as tasks are re-tagged.
    public static let owed = "follow-up"

    /// Every spelling of ``owed`` that should still be recognised.
    public static let owedSpellings: Set<String> = [owed, "promise"]

    /// Whether a tag marks a task as owed, including as the leaf of a hierarchical tag such as
    /// `work/follow-up`.
    public static func marksOwed(_ slug: String) -> Bool {
        owedSpellings.contains(slug) || owedSpellings.contains { slug.hasSuffix("/\($0)") }
    }
}


/// The `#` words that name a *kind* of thing rather than tag it.
///
/// `#bug crash on launch` files a defect; `#bugs` and `#bug-triage` stay ordinary tags, because a
/// sigil that quietly swallowed every word starting with "bug" would be worse than no shorthand at
/// all. Only the exact words below are claimed.
public enum CaptureKindWords {
    public static let words: [String: ItemKind] = [
        "bug": .bug,
        "feature": .feature,
        "task": .reminder,
        "milestone": .milestone,
        "release": .release,
    ]

    /// The kind a tag slug names, if it names one.
    public static func kind(for slug: String) -> ItemKind? {
        words[slug]
    }

    /// The order the grammar sheet lists them in — the two people actually type first.
    public static let hintOrder: [String] = ["bug", "feature", "task", "milestone", "release"]
}
