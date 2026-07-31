import ElephruitCore
@testable import ElephruitFeatures
import Testing

@Suite("Contact editor labels")
struct ContactEditorTests {
    @Test("Email and phone use Personal or Work")
    func reachabilityLabelsDescribeAffinity() {
        #expect(ContactDetailKind.email.editorDefaultLabel == "personal")
        #expect(ContactDetailKind.phone.editorDefaultLabel == "personal")
        #expect(ContactDetailKind.email.editorLabelOptions == ["personal", "work"])
        #expect(ContactDetailKind.phone.editorLabelOptions == ["personal", "work"])
    }

    @Test("Other contact kinds keep their useful choices")
    func otherKindsKeepTheirVocabulary() {
        #expect(ContactDetailKind.address.editorLabelOptions == ["home", "work", "other"])
        #expect(ContactDetailKind.website.editorLabelOptions == ["homepage", "work", "blog", "other"])
    }
}
