import ElephruitCore
import Foundation
import SafariServices

/// Native half of the Safari Web Extension.
///
/// It has one deliberately small authority: validate a browser message and place it in the shared
/// inbox. Elephruit remains the only process that opens the user's library.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        do {
            guard let request = context.inputItems.first as? NSExtensionItem,
                  let message = request.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
                throw ClipMessageError.invalid("Safari sent an empty clipping request.")
            }

            let clip = try ClipMessageDecoder.decode(message)
            let inbox = try WebClipInbox.applicationGroup()
            _ = try inbox.enqueue(clip)

            // The payload is already durable. Opening Elephruit makes a cold-start capture appear
            // immediately; if macOS declines, the app imports it on its next ordinary launch.
            if let url = URL(string: "elephruit://clip/import") {
                context.open(url, completionHandler: nil)
                reply(
                    to: context,
                    message: [
                        "success": true,
                        "queued": true,
                        "openedApp": true,
                        "clipID": clip.id.uuidString,
                    ]
                )
            } else {
                reply(to: context, message: ["success": true, "queued": true, "openedApp": false])
            }
        } catch {
            reply(
                to: context,
                message: [
                    "success": false,
                    "error": (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription,
                ]
            )
        }
    }

    private func reply(to context: NSExtensionContext, message: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: message]
        context.completeRequest(returningItems: [response])
    }
}

private enum ClipMessageError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

private enum ClipMessageDecoder {
    static func decode(_ message: [String: Any]) throws -> WebClip {
        guard message["action"] as? String == "enqueueClip",
              let value = message["clip"] as? [String: Any] else {
            throw ClipMessageError.invalid("The clip request was not recognized.")
        }

        let id = UUID(uuidString: string("id", in: value)) ?? UUID()
        guard let mode = WebClipMode(rawValue: string("mode", in: value)) else {
            throw ClipMessageError.invalid("Choose a valid clipping mode.")
        }
        guard let sourceURL = URL(string: string("sourceURL", in: value)), sourceURL.isWebURL else {
            throw ClipMessageError.invalid("Only HTTP and HTTPS pages can be clipped.")
        }

        let markdown = string("contentMarkdown", in: value)
        let html = optionalString("contentHTML", in: value)
        guard markdown.count <= 8_000_000, (html?.count ?? 0) <= 8_000_000 else {
            throw ClipMessageError.invalid("This page is too large to clip safely.")
        }

        let screenshot = screenshotData(from: optionalString("screenshotData", in: value))
        guard (screenshot?.count ?? 0) <= 24_000_000 else {
            throw ClipMessageError.invalid("This screenshot is too large to save.")
        }

        let canonical = optionalString("canonicalURL", in: value).flatMap(URL.init(string:))
        let clippedAt = optionalString("clippedAt", in: value)
            .flatMap { try? Date($0, strategy: .iso8601) } ?? Date()

        return WebClip(
            id: id,
            mode: mode,
            title: string("title", in: value),
            sourceURL: sourceURL,
            canonicalURL: canonical,
            siteName: optionalString("siteName", in: value),
            author: optionalString("author", in: value),
            excerpt: optionalString("excerpt", in: value),
            contentMarkdown: markdown,
            contentHTML: html,
            comment: string("comment", in: value),
            tagSlugs: value["tagSlugs"] as? [String] ?? [],
            projectHint: optionalString("projectHint", in: value),
            screenshotData: screenshot,
            clippedAt: clippedAt
        )
    }

    private static func string(_ key: String, in value: [String: Any]) -> String {
        value[key] as? String ?? ""
    }

    private static func optionalString(_ key: String, in value: [String: Any]) -> String? {
        guard let result = value[key] as? String, !result.isEmpty else { return nil }
        return result
    }

    private static func screenshotData(from encoded: String?) -> Data? {
        guard let encoded else { return nil }
        let base64 = encoded.split(separator: ",", maxSplits: 1).last.map(String.init) ?? encoded
        return Data(base64Encoded: base64)
    }
}
