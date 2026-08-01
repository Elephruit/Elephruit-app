import ElephruitCore
import Foundation
import Testing

@Suite("Writing a phone number down")
struct PhoneNumberFormattingTests {
    @Test("Ten digits are grouped", arguments: [
        "9524526862",
        "952 452 6862",
        "952-452-6862",
        "952.452.6862",
        "(952) 452-6862",
    ])
    func tenDigitsAreGrouped(_ input: String) {
        #expect(PhoneNumberFormatting.display(input) == "(952) 452-6862")
    }

    @Test("A leading country code of 1 is understood and dropped", arguments: [
        "+19524526862",
        "19524526862",
        "+1 (952) 452-6862",
    ])
    func nanpCountryCode(_ input: String) {
        #expect(PhoneNumberFormatting.display(input) == "(952) 452-6862")
    }

    /// The important half. Anything without exactly one conventional grouping comes back untouched:
    /// a French number regrouped as though it were American is worse than an unformatted one,
    /// because it makes the reader distrust every other number on the page.
    @Test("Anything else is returned exactly as it was given", arguments: [
        "+44 20 7946 0958",     // UK — a different grouping entirely
        "+33 1 42 68 53 00",    // France
        "+61 2 9374 4000",      // Australia
        "611",                  // short code
        "952452",               // partial, still being typed
        "952-452-6862 x14",     // an extension is part of the number
        "1-800-FLOWERS",        // letters
        "",
    ])
    func everythingElseIsUntouched(_ input: String) {
        #expect(PhoneNumberFormatting.display(input) == input)
    }

    @Test("A number that is already formatted is left where it is")
    func idempotent() {
        let once = PhoneNumberFormatting.display("+19524526862")
        #expect(PhoneNumberFormatting.display(once) == once)
    }

    @Test("Only phone details are reformatted")
    func onlyPhones() {
        let phone = ContactDetail(kind: .phone, label: "mobile", value: "+19524526862")
        #expect(phone.displayValue == "(952) 452-6862")
        // The stored value is what dials and what matches a duplicate; it must not move.
        #expect(phone.value == "+19524526862")

        let email = ContactDetail(kind: .email, label: "work", value: "aa.mcnair2@gmail.com")
        #expect(email.displayValue == email.value)
    }
}
