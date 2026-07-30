import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import Foundation
import SwiftData

/// Builds a realistic library to measure against.
///
/// ### Why the text is generated rather than templated
/// An index over "Item 1"…"Item 50000" proves nothing. Every title shares a prefix, every term has
/// the same frequency, and the resulting posting lists are nothing like a real library's — which is
/// exactly the property search performance depends on. A Markov chain over sample prose produces
/// realistic term frequencies: a few very common words, a long tail of rare ones, and titles that
/// genuinely differ from one another.
///
/// Seeded, so a run is reproducible and a regression is a regression rather than a different corpus.
@MainActor
struct CorpusGenerator {
    let seed: UInt64

    init(seed: UInt64 = 0x656C_6570_6872_7569) {
        self.seed = seed
    }

    /// A small deterministic generator. `SystemRandomNumberGenerator` would make runs incomparable.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            // xorshift64*, adequate for corpus generation and dependency-free.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// Source prose, chosen to have the vocabulary a personal library actually contains.
    private static let sourceText = """
    The pitch is less bookkeeping not more features. Three things people say. I have the same list
    in four places. I know I wrote it down somewhere. I do not trust it to still be there next year.
    Ship the pricing page and the announcement by the end of the quarter. Move the reporting tables
    off the primary instance. Agree the launch date with sales before the customer email goes out.
    Draft the positioning note and reference the framing from last quarter. Check the figures
    against the previous period. Book the venue and confirm the catering. Review the migration
    rollback plan with the team. Send the revised table for review. Read about the metro before the
    trip. Borrow the travel guide. Chase the invoice from February. Follow up after the call.
    Consider a usage based tier for smaller teams. Cost it out before committing. The tone should be
    matter of fact rather than promotional. Keep the summary short and the detail linked.
    """

    private static let words: [String] = sourceText
        .split(whereSeparator: { !$0.isLetter })
        .map { $0.lowercased() }

    /// term → the terms that followed it, for a first-order chain.
    private static let chain: [String: [String]] = {
        var chain: [String: [String]] = [:]
        for index in 0..<(words.count - 1) {
            chain[words[index], default: []].append(words[index + 1])
        }
        return chain
    }()

    private func sentence(wordCount: Int, using generator: inout SeededGenerator) -> String {
        guard var current = Self.words.randomElement(using: &generator) else { return "" }
        var result = [current]

        for _ in 1..<max(1, wordCount) {
            guard let next = Self.chain[current]?.randomElement(using: &generator) else {
                current = Self.words.randomElement(using: &generator) ?? current
                result.append(current)
                continue
            }
            current = next
            result.append(current)
        }

        return result.joined(separator: " ")
    }

    /// Fills a store. Returns how many items it wrote.
    @discardableResult
    func populate(
        context: ModelContext,
        notes: Int,
        tasks: Int,
        projects: Int,
        people: Int
    ) throws -> Int {
        var generator = SeededGenerator(state: seed)
        let now = Date()

        // Tags follow a realistic distribution: a handful used constantly, a long tail used once.
        let tagNames = (0..<60).map { "tag-\(sentence(wordCount: 1, using: &generator))-\($0)" }
        var tags: [ElephruitModel.Tag] = []
        for name in tagNames {
            let tag = ElephruitModel.Tag(name: name)
            context.insert(tag)
            tags.append(tag)
        }

        var containers: [Item] = []
        for index in 0..<projects {
            let project = Item(
                kind: .project,
                title: sentence(wordCount: Int.random(in: 2...5, using: &generator), using: &generator),
                body: sentence(wordCount: Int.random(in: 20...60, using: &generator), using: &generator),
                createdAt: now.addingTimeInterval(-Double(index) * 3_600)
            )
            project.status = .open
            project.refreshSearchText()
            context.insert(project)
            containers.append(project)
        }

        for index in 0..<people {
            let person = Item(
                kind: .person,
                title: sentence(wordCount: 2, using: &generator).capitalized,
                createdAt: now.addingTimeInterval(-Double(index) * 600)
            )
            person.refreshSearchText()
            context.insert(person)
        }

        for index in 0..<notes {
            let note = Item(
                kind: .note,
                title: sentence(wordCount: Int.random(in: 3...8, using: &generator), using: &generator),
                body: sentence(wordCount: Int.random(in: 40...200, using: &generator), using: &generator),
                createdAt: now.addingTimeInterval(-Double(index) * 120)
            )
            // Roughly a third tagged, weighted towards the common tags.
            if index % 3 == 0, let tag = tags.prefix(8).randomElement(using: &generator) {
                note.tags = [tag]
            }
            note.refreshSearchText()
            context.insert(note)
        }

        for index in 0..<tasks {
            let task = Item(
                kind: .task,
                title: sentence(wordCount: Int.random(in: 3...9, using: &generator), using: &generator),
                createdAt: now.addingTimeInterval(-Double(index) * 90),
                status: .open
            )
            // A realistic spread: some overdue, some today, some future, many with no date at all.
            switch index % 5 {
            case 0: task.dueAt = now.addingTimeInterval(-Double(index % 30) * 86_400)
            case 1: task.dueAt = now
            case 2: task.dueAt = now.addingTimeInterval(Double(index % 60) * 86_400)
            default: break
            }
            if index % 4 == 0, let container = containers.randomElement(using: &generator) {
                task.parent = container
            }
            if index % 7 == 0 {
                task.status = .completed
                task.completedAt = now
            }
            task.refreshSearchText()
            context.insert(task)
        }

        try context.save()
        return notes + tasks + projects + people
    }
}
