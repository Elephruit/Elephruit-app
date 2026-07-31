import ElephruitCore
import Foundation
import Vision

/// One line of text found on an image, with where it was.
public struct RecognizedLine: Sendable, Hashable {
    public var text: String

    /// How sure the recogniser is, 0 to 1.
    public var confidence: Float

    /// Normalised position, origin bottom-left, as Vision reports it.
    ///
    /// Kept so the review screen can order lines the way they appear on the card — a name is at the
    /// top, a phone number near the bottom, and reading order is most of what makes a scanned card
    /// interpretable.
    public var boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Reading text off an image.
///
/// A protocol so the card-scan flow can be built and tested with a fixture rather than a photograph,
/// and so the on-device recogniser is one conformance rather than a hard dependency in the middle of
/// a feature.
public protocol TextRecognizing: Sendable {
    /// Every line found, in no guaranteed order.
    func recognizeText(in imageData: Data) async throws -> [RecognizedLine]
}

/// The default: recognises nothing.
///
/// Used wherever the feature is not enabled, so the review screen's empty state is a real code path
/// from the first launch.
public struct NoTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageData: Data) async throws -> [RecognizedLine] { [] }
}

/// On-device text recognition through Vision.
///
/// ### Why this needs no entitlement and makes no network request
/// `VNRecognizeTextRequest` runs entirely on the device. `usesLanguageCorrection` uses local
/// language models. Nothing here reaches the network, which is also enforced from below: the app has
/// no network-client entitlement, so an implementation that tried would be refused by the sandbox at
/// the kernel boundary rather than by a promise in a comment.
///
/// Continuity Camera and the file importer both produce image data, and both arrive here. The camera
/// itself is the *system's* — the app never opens an `AVCaptureSession` and therefore needs no camera
/// entitlement and triggers no camera prompt; macOS presents its own capture interface and hands back
/// a file. That is the whole reason the scan flow takes `Data` rather than a device.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognizeText(in imageData: Data) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: lines)
            }

            // Accuracy over speed: a business card is scanned once, and a misread digit in a phone
            // number costs far more than the extra few hundred milliseconds.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(data: imageData).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Interpretation

/// What a scanned card appears to say.
///
/// ### Why every field is a candidate rather than a value
/// Recognition is a guess twice over: once about what the pixels say, and again about which line is a
/// job title and which is a company. Both guesses are wrong often enough that writing the result
/// straight into a contact would produce records nobody trusts. So the scan produces candidates, the
/// review screen shows them beside the original image, and nothing is created until somebody has
/// looked.
public struct ScannedCard: Sendable {
    public var lines: [RecognizedLine]

    public var nameCandidates: [String]
    public var emails: [String]
    public var phones: [String]
    public var urls: [String]
    public var organizationCandidates: [String]
    public var jobTitleCandidates: [String]
    public var addressCandidates: [String]

    public init(
        lines: [RecognizedLine],
        nameCandidates: [String] = [],
        emails: [String] = [],
        phones: [String] = [],
        urls: [String] = [],
        organizationCandidates: [String] = [],
        jobTitleCandidates: [String] = [],
        addressCandidates: [String] = []
    ) {
        self.lines = lines
        self.nameCandidates = nameCandidates
        self.emails = emails
        self.phones = phones
        self.urls = urls
        self.organizationCandidates = organizationCandidates
        self.jobTitleCandidates = jobTitleCandidates
        self.addressCandidates = addressCandidates
    }

    public var isEmpty: Bool {
        nameCandidates.isEmpty && emails.isEmpty && phones.isEmpty
            && organizationCandidates.isEmpty && addressCandidates.isEmpty
    }

    /// The best reading, for pre-filling the review form.
    public var bestName: String? { nameCandidates.first }
}

/// Turns recognised lines into candidate fields.
///
/// Pure, so the whole interpretation is testable against a fixture of lines without an image, a
/// camera, or Vision. The rules are deliberately dull — an address is recognised by shape, a job
/// title by a word list — because a cleverer classifier would be wrong in ways nobody can predict and
/// the user is reviewing the output anyway.
public enum BusinessCardInterpreter {
    public static func interpret(_ lines: [RecognizedLine]) -> ScannedCard {
        // Top to bottom, as the card reads. Vision's origin is bottom-left, so a larger `midY` is
        // higher up — which is where a name almost always is.
        let ordered = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var emails: [String] = []
        var phones: [String] = []
        var urls: [String] = []
        var names: [String] = []
        var organizations: [String] = []
        var titles: [String] = []
        var addresses: [String] = []

        for line in ordered {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // The unambiguous shapes first, so a line holding an email is never also read as a name.
            let words = text.split(separator: " ").map(String.init)

            if let email = words.first(where: ContactDetailRecognizer.isEmail) {
                emails.append(email)
                continue
            }

            if let phone = phoneNumber(in: text) {
                phones.append(phone)
                continue
            }

            if let url = websiteText(in: text) {
                urls.append(url)
                continue
            }

            if looksLikeAddress(text) {
                addresses.append(text)
                continue
            }

            if looksLikeJobTitle(text) {
                titles.append(text)
                continue
            }

            if looksLikeOrganization(text) {
                organizations.append(text)
                continue
            }

            if looksLikeName(text) {
                names.append(text)
                continue
            }

            // Anything left over is a plausible organisation — the line a card carries that is
            // neither a name, a title, nor a detail usually is one.
            organizations.append(text)
        }

        return ScannedCard(
            lines: ordered,
            nameCandidates: names,
            emails: emails,
            phones: phones,
            urls: urls,
            organizationCandidates: organizations,
            jobTitleCandidates: titles,
            addressCandidates: addresses
        )
    }

    /// A phone number written the way cards write them.
    ///
    /// Requires a telephone-ish prefix or enough digits with number punctuation, so a street number
    /// and a postcode are not offered as numbers to dial.
    static func phoneNumber(in text: String) -> String? {
        let stripped = text
            .replacingOccurrences(of: "Tel:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Phone:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Mobile:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "M:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "T:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        return ContactDetailRecognizer.phone(stripped)
    }

    static func websiteText(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespaces)
        guard !candidate.contains(" "), candidate.contains(".") else { return nil }
        guard !ContactDetailRecognizer.isEmail(candidate) else { return nil }

        let lowered = candidate.lowercased()
        guard lowered.hasPrefix("www.") || lowered.hasPrefix("http") || ContactActionURL.websiteURL(candidate) != nil
        else { return nil }

        return candidate
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        let suffixes = [
            "street", "st", "road", "rd", "avenue", "ave", "lane", "ln", "drive", "dr",
            "boulevard", "blvd", "suite", "floor", "way", "court", "ct",
        ]
        let lowered = text.lowercased()

        // A leading number plus a street word, which is what an address on a card looks like.
        let startsWithNumber = text.first?.isNumber ?? false
        let hasStreetWord = suffixes.contains { lowered.contains(" \($0) ") || lowered.hasSuffix(" \($0)") }

        return startsWithNumber && (hasStreetWord || lowered.contains(","))
    }

    static func looksLikeJobTitle(_ text: String) -> Bool {
        let words = [
            "director", "manager", "engineer", "designer", "founder", "partner", "officer",
            "president", "head of", "lead", "consultant", "analyst", "architect", "developer",
            "chief", "vp", "coordinator", "specialist", "principal",
        ]
        let lowered = text.lowercased()
        return words.contains { lowered.contains($0) }
    }

    static func looksLikeOrganization(_ text: String) -> Bool {
        let markers = ["inc", "ltd", "llc", "gmbh", "limited", "co.", "corp", "company", "studio", "group"]
        let lowered = text.lowercased()
        return markers.contains { lowered.hasSuffix(" \($0)") || lowered.hasSuffix(" \($0).") }
    }

    /// Two to four capitalised words and nothing else.
    ///
    /// Narrow on purpose. A line that is *not* recognised as a name still appears on the review
    /// screen and can be promoted with one click, whereas a wrong name is silently accepted by
    /// somebody skimming.
    static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        guard (2...4).contains(words.count) else { return false }

        return words.allSatisfy { word in
            guard let first = word.first else { return false }
            return first.isUppercase && word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "." || $0 == "'" }
        }
    }
}
