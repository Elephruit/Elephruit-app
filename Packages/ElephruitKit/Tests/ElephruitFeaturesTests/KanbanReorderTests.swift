@testable import ElephruitFeatures
import Foundation
import Testing

@MainActor
@Suite("Kanban live reordering")
struct KanbanReorderTests {
    @Test("A card reflows within its current column before release")
    func reordersWithinColumn() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let drag = KanbanDragCoordinator()

        drag.begin(itemID: first, columns: ["doing": [first, second, third]])
        drag.move(to: "doing", relativeTo: third, placeAfter: true)

        #expect(drag.itemIDs(in: "doing") == [second, third, first])
        #expect(
            drag.placement(in: "doing")
                == KanbanPlacement(itemID: first, predecessorID: third, successorID: nil)
        )
    }

    @Test("A cross-column preview reports the exact neighbours to persist")
    func movesBetweenColumnsAtAnExactPosition() throws {
        let moving = UUID()
        let leftBehind = UUID()
        let before = UUID()
        let after = UUID()
        let drag = KanbanDragCoordinator()

        drag.begin(
            itemID: moving,
            columns: ["todo": [moving, leftBehind], "doing": [before, after]]
        )
        drag.move(to: "doing", relativeTo: after, placeAfter: false)

        #expect(drag.itemIDs(in: "todo") == [leftBehind])
        #expect(drag.itemIDs(in: "doing") == [before, moving, after])
        #expect(
            drag.placement(in: "doing")
                == KanbanPlacement(itemID: moving, predecessorID: before, successorID: after)
        )
    }

    @Test("Ending a cancelled drag restores model-backed rendering")
    func cancellationClearsPreview() {
        let item = UUID()
        let drag = KanbanDragCoordinator()

        drag.begin(itemID: item, columns: ["todo": [item]])
        drag.end()

        #expect(!drag.isDragging)
        #expect(drag.targetedColumnKey == nil)
        #expect(drag.itemIDs(in: "todo").isEmpty)
    }

    @Test("The middle of a card is a neutral zone")
    func cardMidpointHasHysteresis() {
        #expect(KanbanCardDropDelegate.placeAfter(at: 10) == false)
        #expect(KanbanCardDropDelegate.placeAfter(at: 24) == nil)
        #expect(KanbanCardDropDelegate.placeAfter(at: 38) == true)
    }
}
