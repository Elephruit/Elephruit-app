// Fills the emulators with a believable stretch of relationship history so every
// surface has something real to show: a roster with quiet people on it, a feed
// with day boundaries, follow-ups in all five buckets plus a completed one, a
// fact ledger with a correction and a restricted row, named and unnamed
// relatives. Run with the emulators up and empty:
//
//   npm run emulators        # terminal 1, fresh state
//   npm run seed             # terminal 2
//
// Everything is written through the real domain planners and the same
// serialize/batch shape the app uses, so the seed cannot drift from the schema
// without the compiler noticing. The one divergence from src/data: the Firebase
// bootstrap is duplicated here, because the app's (src/data/firebase.ts) reads
// import.meta.env, which only exists under Vite.

import { initializeApp } from 'firebase/app'
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
  signInWithEmailAndPassword,
} from 'firebase/auth'
import {
  collection,
  connectFirestoreEmulator,
  doc,
  getDocs,
  getFirestore,
  limit,
  query,
  writeBatch,
} from 'firebase/firestore'
import {
  planCompleteReminder,
  planCreatePerson,
  planCreateReminder,
  planInteractionBundle,
  planObservation,
  planCorrection,
  planRelationshipPair,
  planRelativeCapture,
  planUpdateReminder,
} from '../src/domain/capture.ts'
import type { Observation } from '../src/domain/facts.ts'
import type { InteractionKind } from '../src/domain/interaction.ts'
import type { Person } from '../src/domain/person.ts'
import type { Reminder } from '../src/domain/reminders.ts'
import { assertPlanFits, type WritePlan } from '../src/domain/writePlan.ts'
import { serialize } from '../src/data/converters.ts'

const app = initializeApp({ apiKey: 'demo-api-key', projectId: 'demo-elephruit' })
const auth = getAuth(app)
const db = getFirestore(app)
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
connectFirestoreEmulator(db, '127.0.0.1', 8080)

// The same account the app's "Use the local dev account" button signs in.
const EMAIL = 'dev@local.test'
const PASSWORD = 'local-dev-password'

async function signIn(): Promise<string> {
  try {
    return (await signInWithEmailAndPassword(auth, EMAIL, PASSWORD)).user.uid
  } catch {
    return (await createUserWithEmailAndPassword(auth, EMAIL, PASSWORD)).user.uid
  }
}

// Mirrors src/data/applyPlan.ts against this script's own db handle.
async function apply(uid: string, plan: WritePlan): Promise<void> {
  assertPlanFits(plan)
  const batch = writeBatch(db)
  for (const write of plan) {
    const ref = doc(db, 'users', uid, write.collection, write.id)
    if (write.op === 'set') batch.set(ref, serialize(write.data) as Record<string, unknown>)
    else if (write.op === 'update') batch.update(ref, serialize(write.data) as Record<string, unknown>)
    else batch.delete(ref)
  }
  await batch.commit()
}

/// A date `daysFromNow` days away (negative = past) at a fixed local time.
function on(daysFromNow: number, hour: number, minute = 0): Date {
  const date = new Date()
  date.setDate(date.getDate() + daysFromNow)
  date.setHours(hour, minute, 0, 0)
  return date
}

const uid = await signIn()

const existing = await getDocs(query(collection(db, 'users', uid, 'people'), limit(1)))
if (!existing.empty) {
  console.error(
    'seed refused: this account already has people. Start the emulators fresh\n' +
      '(`npm run emulators`, not `emulators:resume`) or delete the data in the\n' +
      'Emulator UI at http://localhost:4000, then run the seed again.',
  )
  process.exit(1)
}

const now = new Date()

// MARK: People

function person(displayName: string, roleTitle?: string, organizationName?: string): Person {
  const { plan, person: created } = planCreatePerson({ displayName, roleTitle, organizationName }, now)
  peoplePlan.push(...plan)
  return created
}

const peoplePlan: WritePlan = []
const ana = person('Ana Torres', 'Product designer', 'Meridian Labs')
const priya = person('Priya Natarajan', 'Product manager', 'Sundial Systems')
const dave = person('Dave Okafor')
const marisol = person('Marisol Vega', 'Treasurer', 'Harbor Co-op')
const jonas = person('Jonas Weber', 'Photographer')
const sam = person('Sam Whitfield', 'Design lead', 'Sundial Systems')
const elena = person('Elena Brandt', 'Cellist', 'City Orchestra')
await apply(uid, peoplePlan)

// Relatives — one named, two recorded before their names are known.
const tomasCapture = planRelativeCapture(ana, { kind: 'partner', label: 'partner', name: 'Tomás Silva' }, now)
await apply(uid, tomasCapture.plan)
const tomas = tomasCapture.relative

const davesSon = planRelativeCapture(dave, { kind: 'child', label: 'son' }, now)
await apply(uid, davesSon.plan)
const anasMother = planRelativeCapture(ana, { kind: 'parent', label: 'mother' }, now)
await apply(uid, anasMother.plan)

// MARK: Relationships between existing people

await apply(uid, planRelationshipPair({ subjectID: ana.id, otherID: priya.id, kind: 'colleague', customLabel: 'my old PM' }, now).plan)
await apply(uid, planRelationshipPair({ subjectID: priya.id, otherID: sam.id, kind: 'worksWith' }, now).plan)
await apply(uid, planRelationshipPair({ subjectID: dave.id, otherID: marisol.id, kind: 'friend' }, now).plan)

// MARK: Interactions, oldest first

const remindersByTitle = new Map<string, Reminder>()

async function log(
  daysFromNow: number,
  hour: number,
  kind: InteractionKind,
  participants: Person[],
  summary: string,
  discussion = '',
  followUps = '',
): Promise<string> {
  const occurredAt = on(daysFromNow, hour)
  const { plan, interaction, reminders } = planInteractionBundle(
    { kind, participantIDs: participants.map((p) => p.id), summary, discussion, followUps, occurredAt },
    participants,
    occurredAt,
  )
  await apply(uid, plan)
  for (const participant of participants) {
    if (!participant.lastContactAt || participant.lastContactAt < occurredAt) {
      participant.lastContactAt = occurredAt
    }
  }
  for (const reminder of reminders) remindersByTitle.set(reminder.title, reminder)
  return interaction.id
}

await log(-70, 19, 'in-person', [elena], 'Concert, then drinks afterward', 'Season opener. She is auditioning for principal in the winter.')
await log(-50, 15, 'in-person', [sam], 'Coffee about the design-lead search', 'Sundial is hiring two seniors in the fall.')
await log(-21, 13, 'in-person', [ana], 'Long lunch after the design review')
await log(-19, 18, 'phone', [jonas], 'Caught up about the Berlin residency')
await log(-17, 9, 'message', [marisol], 'Reminder about the assessment vote')
await log(-15, 11, 'message', [priya], 'Traded notes on the launch checklist')
await log(-13, 20, 'phone', [dave], 'Planned the lake weekend')
const walkthrough = await log(-12, 14, 'in-person', [ana, priya], 'Studio walkthrough with the Sundial team', 'Priya wants Ana to meet the design leadership before the fall hiring round.', 'Send Priya the intro to Sam Whitfield')
await log(-11, 10, 'in-person', [marisol], 'Co-op budget working session', '', 'Send the co-op budget notes')
await log(-9, 16, 'email', [priya], 'Launch review retro notes')
await log(-8, 12, 'video', [ana], 'Video catch-up on the move logistics')
await log(-6, 9, 'in-person', [dave], 'Helped rig the boat for the regatta', '', 'Ask how the regatta went')
await log(-4, 17, 'message', [tomas], 'Checked in about the clinic start date')
await log(-3, 19, 'message', [ana], 'Photos from the flat hunt in Denver')
await log(-2, 15, 'email', [jonas], 'Reply on the residency application', '', 'Reply about the residency dates')
await log(-1, 18, 'message', [dave], 'Dave sent photos from the lake house', "His son's first regatta — remember to ask how it went. Dock rebuild finally finished after two summers.")
await log(-1, 11, 'video', [marisol], 'Video catch-up on the co-op budget')
await log(0, 8, 'phone', [priya], 'Quick call about the launch review')
const coffee = await log(0, 9, 'in-person', [ana], 'Coffee with Ana — the Denver move is real', 'She is targeting late September and wants intros on the design team side. Tomás starts at the clinic in October.', 'Book flights for Denver trip')

// MARK: Follow-up dates — one per bucket, plus a completed one

const intro = remindersByTitle.get('Send Priya the intro to Sam Whitfield')!
await apply(uid, planUpdateReminder(intro.id, { dueAt: on(-6, 17) }).plan) // overdue
const flights = remindersByTitle.get('Book flights for Denver trip')!
await apply(uid, planUpdateReminder(flights.id, { dueAt: on(0, 21) }).plan) // today
const regatta = remindersByTitle.get('Ask how the regatta went')!
await apply(uid, planUpdateReminder(regatta.id, { dueAt: on(2, 12) }).plan) // upcoming
// "Send the co-op budget notes" and "Reply about the residency dates" stay undated — anytime.

const dinner = planCreateReminder({ title: 'Plan a Lisbon farewell dinner', personIDs: [ana.id, tomas.id], startAt: on(10, 9) }, now)
await apply(uid, dinner.plan) // upcoming, by start date
const fair = planCreateReminder({ title: 'Take Jonas to the print fair', personIDs: [jonas.id], isSomeday: true }, now)
await apply(uid, fair.plan) // someday
const feedback = planCreateReminder({ title: 'Send the portfolio feedback', personIDs: [jonas.id] }, on(-14, 10))
await apply(uid, feedback.plan)
await apply(uid, planCompleteReminder(feedback.reminder.id, on(-12, 15)).plan) // completed

// MARK: Facts

async function fact(
  subject: Person,
  attribute: string,
  value: string,
  daysFromNow: number,
  extra: { confidence?: 'stated' | 'inferred' | 'uncertain'; sensitivity?: 'normal' | 'sensitive' | 'restricted'; sourceInteractionID?: string } = {},
): Promise<Observation> {
  const observedOn = on(daysFromNow, 12)
  const { plan, observation } = planObservation(
    { subjectID: subject.id, attribute, value, observedOn, ...extra },
    observedOn,
  )
  await apply(uid, plan)
  return observation
}

// A corrected fact, so the ledger has history: the old employer row survives,
// superseded, with the note on it.
const oldEmployer = await fact(ana, 'employer', 'Northwind Studio', -400)
const corrected = planCorrection(oldEmployer, { value: 'Meridian Labs' }, 'She moved teams in the spring reorg', on(-90, 12))
await apply(uid, corrected.plan)

await fact(ana, 'location', 'Lisbon', -300)
await fact(ana, 'health', 'Recovering from knee surgery', -30, { sensitivity: 'restricted' })
await fact(ana, 'conversationTopic', 'Denver move logistics', 0, { sourceInteractionID: coffee })
await fact(priya, 'interest', 'Trail running', -45)
await fact(priya, 'conversationTopic', 'Fall hiring round', -12, { sourceInteractionID: walkthrough })
await fact(dave, 'family', 'Two kids', -60, { confidence: 'inferred' })
await fact(dave, 'giftIdea', 'Sailing gloves', -6)
await fact(davesSon.relative, 'school', 'Riverside Middle School', -6)
await fact(jonas, 'location', 'Berlin', -800) // past the location shelf life — shows decayed confidence
await fact(marisol, 'foodAndDrink', 'Flat white, oat milk', -11)
await fact(elena, 'lifeEvent', 'Auditioning for principal cellist this winter', -70)

// MARK: Done

const counts = await Promise.all(
  (['people', 'interactions', 'relationships', 'observations', 'reminders'] as const).map(async (name) => {
    const snapshot = await getDocs(collection(db, 'users', uid, name))
    return `${name} ${snapshot.size}`
  }),
)
console.log(`seeded ${EMAIL}: ${counts.join(', ')}`)
process.exit(0)
