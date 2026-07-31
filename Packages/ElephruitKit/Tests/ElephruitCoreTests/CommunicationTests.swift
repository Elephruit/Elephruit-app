import ElephruitCore
import Foundation
import Testing

/// The vocabulary, and the rules that keep it honest.
///
/// Everything here is a pure value type or a pure function, so none of it needs a store, a clock, a
/// window, or a compose sheet. That is the point of putting the whole state machine in Core: the
/// claims the app is allowed to make are decided by code that can be tested exhaustively.
@Suite("Communication states and evidence")
struct CommunicationStateTests {
    @Test("No channel claims it can report delivery")
    func nothingReportsDelivery() {
        // The load-bearing assertion of the whole module. There is no supported macOS API that tells
        // a third-party app an iMessage was delivered or read, and the mail provider APIs this design
        // allows for report submission rather than arrival. If a future SDK changes that, this test
        // is the thing that has to be changed deliberately in order to start making the claim.
        for channel in CommunicationChannel.allCases {
            #expect(!channel.canReportDelivery, "\(channel.rawValue) must not claim delivery evidence")
        }
    }

    @Test("Only email can ever be provider-verified")
    func onlyEmailHasAProvider() {
        #expect(CommunicationChannel.email.canBeProviderVerified)

        for channel in CommunicationChannel.allCases where channel != .email {
            #expect(!channel.canBeProviderVerified)
        }
    }

    @Test("Only email and Messages have a native composer")
    func sharingServicesAreTheTwoAppleOffers() {
        #expect(CommunicationChannel.email.hasSharingService)
        #expect(CommunicationChannel.message.hasSharingService)
        #expect(!CommunicationChannel.phoneCall.hasSharingService)
        #expect(!CommunicationChannel.facetimeVideo.hasSharingService)
        #expect(!CommunicationChannel.facetimeAudio.hasSharingService)
    }

    @Test("Handing off is not sending, and sending is not delivering")
    func theThreeLinesAreDrawnWhereTheyShouldBe() {
        // A sharing service finishing says the service finished. Whether the user pressed Send is
        // not something the callback can distinguish, so `shareCompleted` must sit below the line.
        #expect(!CommunicationState.shareCompleted.claimsTheMessageLeft)
        #expect(!CommunicationState.composerOpened.claimsTheMessageLeft)
        #expect(CommunicationState.submitted.claimsTheMessageLeft)
        #expect(CommunicationState.userConfirmedSent.claimsTheMessageLeft)
        #expect(CommunicationState.providerVerifiedSent.claimsTheMessageLeft)

        // Only one state claims arrival, and nothing in the app can produce it.
        for state in CommunicationState.allCases where state != .delivered {
            #expect(!state.claimsDelivery, "\(state.rawValue) must not claim delivery")
        }
        #expect(CommunicationState.delivered.claimsDelivery)
    }

    @Test("Reaching out means somebody said the message went")
    func onlyStatedOrVerifiedSendsCountAsContact() {
        let counting = CommunicationState.allCases.filter(\.countsAsReachingOut)
        #expect(Set(counting) == [.userConfirmedSent, .providerVerifiedSent, .delivered])

        // The three that most invite a false positive, named individually so a future edit that
        // widened the set would fail here rather than in somebody's last-contact line.
        #expect(!CommunicationState.composerOpened.countsAsReachingOut)
        #expect(!CommunicationState.shareCompleted.countsAsReachingOut)
        #expect(!CommunicationState.unknown.countsAsReachingOut)
    }

    @Test("A URL scheme reports nothing back")
    func urlSchemesCannotReportCompletion() {
        #expect(!CommunicationLaunchMechanism.urlScheme.reportsCompletion)
        #expect(!CommunicationLaunchMechanism.manual.reportsCompletion)
        #expect(CommunicationLaunchMechanism.sharingService.reportsCompletion)
        #expect(CommunicationLaunchMechanism.providerAPI.reportsCompletion)
    }

    @Test("A provider outranks a person, and a person outranks a callback")
    func evidenceAuthorityIsOrdered() {
        #expect(CommunicationEvidence.inference.authority < CommunicationEvidence.systemCallback.authority)
        #expect(CommunicationEvidence.systemCallback.authority < CommunicationEvidence.userConfirmation.authority)
        #expect(CommunicationEvidence.userConfirmation.authority < CommunicationEvidence.providerAPI.authority)
        #expect(CommunicationEvidence.importedRecord.authority == CommunicationEvidence.providerAPI.authority)
    }

    @Test("A call that reached voicemail is not a call that happened")
    func onlyAConnectedCallCountsAsContact() {
        #expect(CallOutcome.connected.countsAsContact)
        #expect(!CallOutcome.noAnswer.countsAsContact)
        #expect(!CallOutcome.leftVoicemail.countsAsContact)
        #expect(!CallOutcome.canceled.countsAsContact)
    }

    @Test("Maps and websites are not communications")
    func onlyChannelsThatReachSomebodyMap() {
        #expect(CommunicationChannel(contactChannel: .maps) == nil)
        #expect(CommunicationChannel(contactChannel: .web) == nil)

        for contact in ContactChannel.allCases where contact.isExternallyVisible {
            let channel = CommunicationChannel(contactChannel: contact)
            #expect(channel != nil, "\(contact.rawValue) reaches a person and needs a communication channel")
            #expect(channel?.contactChannel == contact, "the mapping must round-trip")
        }
    }
}

// MARK: - Transitions

@Suite("Communication transitions")
struct CommunicationTransitionTests {
    private func resolve(
        _ current: CommunicationState,
        _ currentEvidence: CommunicationEvidence,
        _ incoming: CommunicationState,
        _ incomingEvidence: CommunicationEvidence
    ) -> CommunicationTransitionResult {
        CommunicationTransitionPolicy.resolve(
            current: current,
            currentEvidence: currentEvidence,
            incoming: incoming,
            incomingEvidence: incomingEvidence
        )
    }

    @Test("Certainty only ever increases")
    func strongerClaimsApply() {
        #expect(resolve(.draftPrepared, .inference, .composerOpened, .systemCallback) == .applied)
        #expect(resolve(.composerOpened, .systemCallback, .shareCompleted, .systemCallback) == .applied)
        #expect(resolve(.shareCompleted, .systemCallback, .userConfirmedSent, .userConfirmation) == .applied)
        #expect(
            resolve(.userConfirmedSent, .userConfirmation, .providerVerifiedSent, .providerAPI) == .applied,
            "a provider verifying a send the user already confirmed is the upgrade this exists for"
        )
    }

    @Test("A late weak signal cannot undo a strong one")
    func weakerClaimsAreIgnored() {
        // The failure this prevents: a share callback arriving after the user has already confirmed,
        // rewriting "Email sent" back to "handed off".
        #expect(resolve(.userConfirmedSent, .userConfirmation, .shareCompleted, .systemCallback) == .weakerClaim)
        #expect(resolve(.providerVerifiedSent, .providerAPI, .userConfirmedSent, .userConfirmation) == .weakerClaim)
        #expect(resolve(.shareCompleted, .systemCallback, .composerOpened, .systemCallback) == .weakerClaim)
    }

    @Test("Taking back a send needs a better source than the one that claimed it")
    func failuresNeedAuthority() {
        // A framework callback cannot overrule a person who watched themselves press Send.
        #expect(resolve(.userConfirmedSent, .userConfirmation, .failed, .systemCallback) == .weakerEvidence)

        // A provider holding the actual record can.
        #expect(resolve(.userConfirmedSent, .userConfirmation, .failed, .providerAPI) == .applied)

        // Nothing has claimed the message left yet, so an equally authoritative source may cancel it.
        #expect(resolve(.composerOpened, .systemCallback, .canceled, .systemCallback) == .applied)
    }

    @Test("The same status twice changes nothing")
    func duplicatesAreRecognised() {
        #expect(resolve(.shareCompleted, .systemCallback, .shareCompleted, .systemCallback) == .duplicate)

        // Unless a better source is now saying it, which is a genuine strengthening.
        #expect(resolve(.submitted, .inference, .submitted, .providerAPI) == .applied)
    }

    @Test("Unknown is a resting state, never a signal")
    func unknownIsNeverApplied() {
        #expect(resolve(.composerOpened, .systemCallback, .unknown, .providerAPI) == .notASignal)
        #expect(resolve(.draftPrepared, .inference, .unknown, .userConfirmation) == .notASignal)
    }

    @Test("Every ordered pair either raises the claim or is refused for a stated reason")
    func theTableIsTotal() {
        // Exhaustive rather than illustrative: with ten states and five evidence kinds there are two
        // and a half thousand combinations, and the one that matters is whichever one nobody thought
        // to write a case for. The invariant is that an applied transition never *lowers* the claim
        // unless the incoming evidence is strictly better.
        for current in CommunicationState.allCases {
            for currentEvidence in CommunicationEvidence.allCases {
                for incoming in CommunicationState.allCases {
                    for incomingEvidence in CommunicationEvidence.allCases {
                        let result = resolve(current, currentEvidence, incoming, incomingEvidence)
                        guard result == .applied, incoming.claimStrength < current.claimStrength else { continue }

                        #expect(
                            incomingEvidence.authority > currentEvidence.authority
                                || incoming == .failed || incoming == .canceled,
                            """
                            \(current.rawValue)/\(currentEvidence.rawValue) → \
                            \(incoming.rawValue)/\(incomingEvidence.rawValue) lowered the claim \
                            without better evidence
                            """
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Labels

@Suite("Communication status labels")
struct CommunicationStatusLabelTests {
    private func intent(
        channel: CommunicationChannel = .email,
        state: CommunicationState,
        evidence: CommunicationEvidence = .systemCallback,
        mechanism: CommunicationLaunchMechanism = .sharingService,
        providerName: String? = nil,
        recipients: [String] = ["maya@example.com"],
        failure: CommunicationFailure? = nil
    ) -> CommunicationIntent {
        CommunicationIntent(
            channel: channel,
            intendedRecipients: recipients.map { CommunicationRecipient(handle: $0) },
            launchMechanism: mechanism,
            state: state,
            evidence: evidence,
            providerName: providerName,
            failure: failure
        )
    }

    @Test("A composer that opened says so, and says the outcome is unknown")
    func composerOpened() {
        let urlLaunch = CommunicationStatusLabel.make(
            for: intent(channel: .message, state: .composerOpened, mechanism: .urlScheme)
        )
        #expect(urlLaunch.headline == "Message initiated")
        #expect(urlLaunch.detail == "final sending status unknown")
    }

    @Test("A completed share is handed off, never delivered")
    func shareCompleted() {
        let label = CommunicationStatusLabel.make(for: intent(state: .shareCompleted))
        #expect(label.headline == "Email handed off to your mail app")
        #expect(label.detail == "recipient intended: maya@example.com")

        // The word that must never appear on the strength of a share callback.
        #expect(!label.sentence.lowercased().contains("delivered"))
        #expect(!label.headline.lowercased().contains("sent"))
    }

    @Test("A user's word and a provider's record read differently")
    func confirmationsAreAttributed() {
        let confirmed = CommunicationStatusLabel.make(
            for: intent(state: .userConfirmedSent, evidence: .userConfirmation)
        )
        #expect(confirmed.headline == "Email sent")
        #expect(confirmed.detail == "confirmed by you")

        let verified = CommunicationStatusLabel.make(
            for: intent(state: .providerVerifiedSent, evidence: .providerAPI, providerName: "Gmail")
        )
        #expect(verified.headline == "Email submitted")
        #expect(verified.detail == "verified by Gmail")
    }

    @Test("A failure says what went wrong in words, never in a code")
    func failuresStayReadable() {
        let label = CommunicationStatusLabel.make(
            for: intent(
                state: .failed,
                failure: CommunicationFailure(
                    summary: "The composer could not be opened.",
                    technicalDetail: "NSCocoaErrorDomain 4097"
                )
            )
        )

        #expect(label.needsAttention)
        #expect(label.sentence == "Email not sent · The composer could not be opened.")
        #expect(!label.sentence.contains("4097"), "an error code must not reach a timeline row")
    }

    @Test("A logged call names the outcome and says who says so")
    func callsAreManual() {
        let label = CommunicationStatusLabel.make(for: .connected, channel: .phoneCall)
        #expect(label.sentence == "Call logged · connected · confirmed manually")
    }

    @Test("A reported call is described by what happened, not by the state it reached")
    func callOutcomesOverrideTheStateLabel() {
        // A call the user reports on reaches `userConfirmedSent` whether or not anybody picked up —
        // they confirmed the call was placed. Describing that as "Call sent · confirmed by you" is
        // odd for a connected call and misleading for a voicemail.
        var voicemail = intent(channel: .phoneCall, state: .userConfirmedSent, evidence: .userConfirmation)
        voicemail.callOutcome = .leftVoicemail

        let label = CommunicationStatusLabel.make(for: voicemail)
        #expect(label.sentence == "Call logged · left voicemail · confirmed manually")
        #expect(!voicemail.countsAsContact, "reaching somebody's voicemail is reaching their voicemail")

        var connected = voicemail
        connected.callOutcome = .connected
        #expect(connected.countsAsContact)

        // Without an outcome the state decides, which is what every other channel does.
        var email = intent(state: .userConfirmedSent, evidence: .userConfirmation)
        email.callOutcome = nil
        #expect(email.countsAsContact)
    }

    @Test("No label claims delivery unless the state does")
    func deliveryNeverLeaksIntoALabel() {
        for state in CommunicationState.allCases where state != .delivered {
            for evidence in CommunicationEvidence.allCases {
                let label = CommunicationStatusLabel.make(
                    for: intent(state: state, evidence: evidence, providerName: "Gmail")
                )
                #expect(
                    !label.sentence.lowercased().contains("deliver"),
                    "\(state.rawValue)/\(evidence.rawValue) produced “\(label.sentence)”"
                )
            }
        }
    }
}

// MARK: - Asking

@Suite("Asking whether a message was sent")
struct CommunicationConfirmationPolicyTests {
    private let now = FixedDateProvider.reference.now

    private func handoff(
        mechanism: CommunicationLaunchMechanism = .urlScheme,
        state: CommunicationState = .composerOpened,
        askCount: Int = 0,
        lastAskedAt: Date? = nil,
        dismissedAt: Date? = nil
    ) -> CommunicationIntent {
        CommunicationIntent(
            channel: .message,
            launchMechanism: mechanism,
            state: state,
            askCount: askCount
        ).with(lastAskedAt: lastAskedAt, dismissedAt: dismissedAt)
    }

    @Test("A handoff nobody can report on is worth asking about")
    func urlHandoffsAreAsked() {
        #expect(handoff().shouldAskForConfirmation(now: now))
    }

    @Test("A sharing service already answered")
    func callbacksAreNotSecondGuessed() {
        // Asking after a callback is asking the user to do the framework's job, and it is the fastest
        // way to make the prompt feel like nagging.
        #expect(!handoff(mechanism: .sharingService).shouldAskForConfirmation(now: now))
    }

    @Test("A settled record has nothing to ask about")
    func settledRecordsAreLeftAlone() {
        for state in CommunicationState.allCases where state.isSettled {
            #expect(!handoff(state: state).shouldAskForConfirmation(now: now))
        }
    }

    @Test("A dismissal is permanent")
    func dismissalStopsItForever() {
        let dismissed = handoff(dismissedAt: now.addingTimeInterval(-86_400 * 30))
        #expect(!dismissed.shouldAskForConfirmation(now: now.addingTimeInterval(86_400 * 365)))
    }

    @Test("Two asks, and no more")
    func theAskBudgetIsTwo() {
        let once = handoff(askCount: 1, lastAskedAt: now.addingTimeInterval(-3_600))
        #expect(once.shouldAskForConfirmation(now: now))

        let twice = handoff(askCount: 2, lastAskedAt: now.addingTimeInterval(-86_400))
        #expect(!twice.shouldAskForConfirmation(now: now))
    }

    @Test("Not twice in five minutes")
    func askingIsRateLimited() {
        let recent = handoff(askCount: 1, lastAskedAt: now.addingTimeInterval(-60))
        #expect(!recent.shouldAskForConfirmation(now: now))
        #expect(recent.shouldAskForConfirmation(now: now.addingTimeInterval(300)))
    }

    @Test("The question names who it is about")
    func theQuestionIsSpecific() {
        let toMaya = CommunicationIntent(
            channel: .message,
            intendedRecipients: [CommunicationRecipient(handle: "5125550192", displayName: "Maya")]
        )
        #expect(toMaya.confirmationQuestion() == "Did you send this message to Maya?")

        let call = CommunicationIntent(
            channel: .phoneCall,
            intendedRecipients: [CommunicationRecipient(handle: "5125550192", displayName: "Maya")]
        )
        #expect(call.confirmationQuestion() == "Did you make this call to Maya?")

        let anonymous = CommunicationIntent(channel: .email)
        #expect(anonymous.confirmationQuestion() == "Did you send this email?")
    }
}

private extension CommunicationIntent {
    /// The two ask-tracking fields, set on a value that is otherwise built by the initialiser.
    func with(lastAskedAt: Date?, dismissedAt: Date?) -> CommunicationIntent {
        var copy = self
        copy.lastAskedAt = lastAskedAt
        copy.dismissedAt = dismissedAt
        return copy
    }
}
