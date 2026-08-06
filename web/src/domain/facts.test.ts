import { describe, expect, it } from 'vitest'
import {
  FactAttributes,
  attributeLabel,
  currentValues,
  customAttribute,
  daysSinceConfirmed,
  effectiveConfidence,
  history,
  isMultiValued,
  isStale,
  populatedAttributes,
  staleObservations,
  valueOf,
  type Observation,
} from './facts'

const day = (iso: string) => new Date(`${iso}T12:00:00`)

let counter = 0
function obs(overrides: Partial<Observation>): Observation {
  counter += 1
  const observedOn = overrides.observedOn ?? day('2026-01-01')
  return {
    id: `obs-${counter}`,
    subjectID: 'ana',
    attribute: FactAttributes.quickFact,
    value: 'something',
    observedOn,
    effectiveOn: null,
    lastConfirmedOn: observedOn,
    confidence: 'stated',
    sensitivity: 'normal',
    sourceInteractionID: null,
    supersedesID: null,
    supersededOn: null,
    correctionNote: null,
    createdAt: observedOn,
    ...overrides,
  }
}

describe('the ledger', () => {
  it('lets the newest observation win a single-valued attribute even when nothing was superseded', () => {
    const austin = obs({ attribute: FactAttributes.location, value: 'Austin', observedOn: day('2025-03-01') })
    const portland = obs({ attribute: FactAttributes.location, value: 'Portland', observedOn: day('2026-02-01') })
    const all = [austin, portland]

    expect(currentValues(all, FactAttributes.location).map((o) => o.value)).toEqual(['Portland'])
    expect(valueOf(all, FactAttributes.location)).toBe('Portland')
    expect(history(all, FactAttributes.location).map((o) => o.value)).toEqual(['Austin'])
  })

  it('keeps every current value of a multi-valued attribute, newest first', () => {
    const hiking = obs({ attribute: FactAttributes.like, value: 'hiking', observedOn: day('2025-01-01') })
    const jazz = obs({ attribute: FactAttributes.like, value: 'jazz', observedOn: day('2026-01-01') })
    const superseded = obs({
      attribute: FactAttributes.like,
      value: 'running',
      observedOn: day('2026-03-01'),
      supersededOn: day('2026-04-01'),
    })

    const current = currentValues([hiking, jazz, superseded], FactAttributes.like)
    expect(current.map((o) => o.value)).toEqual(['jazz', 'hiking'])
  })

  it('puts a superseded row in history even when it is the newest', () => {
    const wrong = obs({
      attribute: FactAttributes.employer,
      value: 'Acme (misheard)',
      observedOn: day('2026-05-01'),
      supersededOn: day('2026-05-02'),
      correctionNote: 'I misheard this',
    })
    const right = obs({ attribute: FactAttributes.employer, value: 'Apex', observedOn: day('2026-04-01') })

    expect(currentValues([wrong, right], FactAttributes.employer).map((o) => o.value)).toEqual(['Apex'])
    expect(history([wrong, right], FactAttributes.employer).map((o) => o.value)).toEqual(['Acme (misheard)'])
  })

  it('orders populated attributes curated-first, then the rest alphabetically', () => {
    const all = [
      obs({ attribute: 'zebra fund' }),
      obs({ attribute: FactAttributes.location, value: 'Austin' }),
      obs({ attribute: 'allergy' }),
      obs({ attribute: FactAttributes.significance, value: 'college roommate' }),
      obs({ attribute: FactAttributes.like, value: 'jazz', supersededOn: day('2026-01-02') }),
    ]

    expect(populatedAttributes(all)).toEqual([
      FactAttributes.significance,
      FactAttributes.location,
      'allergy',
      'zebra fund',
    ])
  })
})

describe('staleness', () => {
  it('marks a location stale only after its 730-day shelf life passes', () => {
    const o = obs({ attribute: FactAttributes.location, value: 'Austin', observedOn: day('2024-01-01') })
    const exactly = new Date(day('2024-01-01').getTime() + 730 * 86_400_000)
    const past = new Date(day('2024-01-01').getTime() + 731 * 86_400_000)

    expect(isStale(o, exactly)).toBe(false)
    expect(isStale(o, past)).toBe(true)
  })

  it('never marks shelf-life-free attributes stale, including the estimator inputs', () => {
    const decade = day('2036-01-01')
    expect(isStale(obs({ attribute: FactAttributes.significance }), decade)).toBe(false)
    expect(isStale(obs({ attribute: FactAttributes.observedAge, value: '6' }), decade)).toBe(false)
    expect(isStale(obs({ attribute: FactAttributes.schoolGrade, value: '8' }), decade)).toBe(false)
  })

  it('decays displayed confidence to Unconfirmed without touching the stored value', () => {
    const o = obs({ attribute: FactAttributes.lookingFor, value: 'a dog trainer', observedOn: day('2025-01-01') })
    expect(effectiveConfidence(o, day('2026-08-01'))).toBe('uncertain')
    expect(o.confidence).toBe('stated')
    expect(effectiveConfidence(o, day('2025-02-01'))).toBe('stated')
  })

  it('lists stale facts oldest-confirmed first and counts days from start of day, never negative', () => {
    const older = obs({ attribute: FactAttributes.employer, value: 'Acme', observedOn: day('2024-01-01') })
    const newer = obs({ attribute: FactAttributes.location, value: 'Austin', observedOn: day('2024-04-01') })
    const fresh = obs({ attribute: FactAttributes.location, value: 'Portland', observedOn: day('2026-08-01') })

    expect(staleObservations([newer, fresh, older], day('2026-08-06')).map((o) => o.value)).toEqual([
      'Acme',
      'Austin',
    ])
    expect(daysSinceConfirmed(obs({ observedOn: day('2026-12-25') }), day('2026-08-06'))).toBe(0)
  })
})

describe('customAttribute', () => {
  it('folds typed text back into the curated set by raw value or display label', () => {
    expect(customAttribute('School')).toBe(FactAttributes.school)
    expect(customAttribute('lives in')).toBe(FactAttributes.location)
    expect(customAttribute('GIFT IDEAS')).toBe(FactAttributes.giftIdea)
  })

  it('normalises whitespace and case for genuinely new attributes', () => {
    expect(customAttribute('  Food   Allergy ')).toBe('food allergy')
    expect(customAttribute('HEALTH')).toBe(FactAttributes.health)
  })

  it('returns null for nothing at all', () => {
    expect(customAttribute('   ')).toBeNull()
    expect(customAttribute('')).toBeNull()
  })

  it('labels an uncurated attribute by capitalising its words', () => {
    expect(attributeLabel('food allergy')).toBe('Food Allergy')
    expect(isMultiValued('food allergy')).toBe(true)
  })
})
