import ElephruitFeatures
import Foundation
import Testing

/// Typing a name at a focused list.
///
/// The whole behaviour is a timing rule, and a timing rule tested by waiting is a test that is slow
/// and occasionally wrong. The buffer takes the clock as an argument for exactly this reason.
@Suite("Type to select")
struct TypeToSelectTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Letters typed together make one word")
    func lettersAccumulate() {
        var buffer = TypeToSelectBuffer()

        #expect(buffer.append("m", at: start) == "m")
        #expect(buffer.append("a", at: start.addingTimeInterval(0.1)) == "ma")
        #expect(buffer.append("y", at: start.addingTimeInterval(0.2)) == "may")
    }

    /// Too long and pressing `s` twice never reaches the second S.
    @Test("A pause starts a new word")
    func pauseResets() {
        var buffer = TypeToSelectBuffer()
        _ = buffer.append("m", at: start)

        #expect(buffer.append("a", at: start.addingTimeInterval(2)) == "a")
    }

    @Test("The boundary is the interval, not almost the interval")
    func boundary() {
        var buffer = TypeToSelectBuffer()
        _ = buffer.append("m", at: start)

        var justInside = buffer
        #expect(justInside.append("a", at: start.addingTimeInterval(TypeToSelectBuffer.interval)) == "ma")

        var justOutside = buffer
        #expect(
            justOutside.append("a", at: start.addingTimeInterval(TypeToSelectBuffer.interval + 0.01)) == "a"
        )
    }

    @Test("A fresh buffer has already expired, so nothing is shown before anything is typed")
    func freshBufferIsExpired() {
        #expect(TypeToSelectBuffer().hasExpired(at: start))
    }

    @Test("A buffer expires once the interval has passed")
    func expiry() {
        var buffer = TypeToSelectBuffer()
        _ = buffer.append("m", at: start)

        #expect(!buffer.hasExpired(at: start.addingTimeInterval(0.1)))
        #expect(buffer.hasExpired(at: start.addingTimeInterval(1)))
    }

    @Test("Clearing empties it")
    func clearing() {
        var buffer = TypeToSelectBuffer()
        _ = buffer.append("m", at: start)
        buffer.clear()

        #expect(buffer.text.isEmpty)
        #expect(buffer.hasExpired(at: start))
    }

    /// Each keystroke keeps the buffer alive, so a name typed steadily never breaks in the middle.
    @Test("Each keystroke restarts the clock")
    func keystrokesExtendTheWindow() {
        var buffer = TypeToSelectBuffer()
        var time = start

        for character in "wolfeschlegelstein" {
            time = time.addingTimeInterval(0.4)
            _ = buffer.append(character, at: time)
        }

        #expect(buffer.text == "wolfeschlegelstein")
    }
}
