import { describe, expect, it } from 'vitest'
import type { DossierProposal } from '../ai/dossier'
import { makeObservation, makePerson } from './capture'
import {
  buildDossierDraft,
  dossierTargetOptions,
  includedCount,
  planFromDossierDraft,
  validateDossierDraft,
} from './dossier'
import type { Person } from './person'

const NOW = new Date('2026-08-06T15:00:00')

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/\s+/g, '-')}`, ...overrides }
}

const PROPOSAL: DossierProposal = {
  subject: { proposedName: 'Kelly Tsaur', roleTitle: 'Head of Payer/Provider Industry Vertical', organizationName: 'ZS' },
  facts: [
    {
      attribute: 'role',
      value: 'Head of Payer/Provider Industry Vertical',
      confidence: 'stated',
      sensitivity: 'normal',
      evidence: 'Kelly Tsaur, Head of Payer/Provider Industry Vertical',
      sourceAttachmentID: 'file-1',
      pageNumber: 1,
    },
    {
      attribute: 'employer',
      value: 'ZS',
      confidence: 'stated',
      sensitivity: 'normal',
      evidence: 'joined ZS in 2019',
      sourceAttachmentID: 'file-1',
      pageNumber: 1,
    },
    {
      attribute: 'health',
      value: 'Recovering from knee surgery',
      confidence: 'stated',
      sensitivity: 'sensitive',
      evidence: 'out after knee surgery',
      sourceAttachmentID: 'file-2',
      pageNumber: 2,
    },
  ],
  relationships: [
    {
      kind: 'colleague',
      label: null,
      otherName: 'Harbinder Raina',
      facts: [{ attribute: 'employer', value: 'ZS', evidence: 'works alongside', sourceAttachmentID: 'file-1', pageNumber: 1 }],
    },
  ],
  followUps: [
    { title: 'Review the payer landscape deck', evidence: 'suggest reviewing', sourceAttachmentID: 'file-1', pageNumber: 3 },
  ],
  warnings: ['A phone number was omitted.'],
}

const SOURCES = [
  { attachmentID: 'file-1', displayName: 'kelly-dossier.pdf', mimeType: 'application/pdf', byteSize: 1000, sha256: 'aaa', pageCount: 3 },
  { attachmentID: 'file-2', displayName: 'notes.docx', mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', byteSize: 500, sha256: 'bbb', pageCount: null },
]

describe('dossierTargetOptions', () => {
  it('ranks exact name matches high, offers possibles, and always offers create', () => {
    const exact = person('Kelly Tsaur')
    const sameFirst = person('Kelly Brand')
    const options = dossierTargetOptions(PROPOSAL, [exact, sameFirst, person('Dave Okafor')])
    expect(options[0]).toMatchObject({ kind: 'existing', confidence: 'high' })
    expect(options.some((o) => o.kind === 'existing' && o.confidence === 'possible' && o.person.id === sameFirst.id)).toBe(true)
    expect(options.some((o) => o.kind === 'create' && o.name === 'Kelly Tsaur')).toBe(true)
  })
})

describe('buildDossierDraft', () => {
  it('includes normal facts, excludes sensitive facts and follow-ups by default', () => {
    const draft = buildDossierDraft(PROPOSAL, { mode: 'create', name: 'Kelly Tsaur' }, [])
    expect(draft.facts.filter((f) => f.included).map((f) => f.attribute)).toEqual(['role', 'employer'])
    expect(draft.facts.find((f) => f.attribute === 'health')?.included).toBe(false)
    expect(draft.followUps.every((f) => !f.included)).toBe(true)
    expect(draft.relationships[0].included).toBe(true) // named other
  })

  it('detects a conflict only for a differing single-valued current value', () => {
    const kelly = person('Kelly Tsaur')
    const existingRole = makeObservation(
      { subjectID: kelly.id, attribute: 'role', value: 'Director of Strategy' },
      new Date('2025-01-01T12:00:00'),
    )
    const sameEmployer = makeObservation(
      { subjectID: kelly.id, attribute: 'employer', value: 'ZS' },
      new Date('2025-01-01T12:00:00'),
    )
    const draft = buildDossierDraft(PROPOSAL, { mode: 'existing', person: kelly }, [existingRole, sameEmployer])
    const role = draft.facts.find((f) => f.attribute === 'role')!
    const employer = draft.facts.find((f) => f.attribute === 'employer')!
    expect(role.conflict?.current.id).toBe(existingRole.id)
    expect(role.conflict?.resolution).toBeNull()
    expect(employer.conflict).toBeNull() // same value, no conflict
  })
})

describe('validateDossierDraft', () => {
  it('blocks until conflicts on included facts are resolved', () => {
    const kelly = person('Kelly Tsaur')
    const existingRole = makeObservation(
      { subjectID: kelly.id, attribute: 'role', value: 'Director of Strategy' },
      new Date('2025-01-01T12:00:00'),
    )
    const draft = buildDossierDraft(PROPOSAL, { mode: 'existing', person: kelly }, [existingRole])
    expect(validateDossierDraft(draft).length).toBeGreaterThan(0)

    const resolved = {
      ...draft,
      facts: draft.facts.map((f) => (f.conflict ? { ...f, conflict: { ...f.conflict, resolution: 'replace' as const } } : f)),
    }
    expect(validateDossierDraft(resolved)).toEqual([])
  })

  it('requires a target', () => {
    const draft = buildDossierDraft(PROPOSAL, { mode: 'create', name: '' }, [])
    expect(validateDossierDraft(draft).some((p) => p.message.includes('who'))).toBe(true)
  })
})

describe('planFromDossierDraft', () => {
  it('replace-resolutions supersede through the correction chain with document provenance', () => {
    const kelly = person('Kelly Tsaur')
    const existingRole = makeObservation(
      { subjectID: kelly.id, attribute: 'role', value: 'Director of Strategy' },
      new Date('2025-01-01T12:00:00'),
    )
    let draft = buildDossierDraft(PROPOSAL, { mode: 'existing', person: kelly }, [existingRole])
    draft = {
      ...draft,
      facts: draft.facts.map((f) => (f.conflict ? { ...f, conflict: { ...f.conflict, resolution: 'replace' as const } } : f)),
    }

    const { plan } = planFromDossierDraft(draft, { targetPerson: kelly, existingPeople: [kelly], sources: SOURCES }, NOW)

    const supersede = plan.find((w) => w.op === 'update' && w.collection === 'observations' && w.id === existingRole.id)
    expect(supersede).toBeTruthy()
    const replacement = plan.find(
      (w) =>
        w.op === 'set' &&
        w.collection === 'observations' &&
        (w.data as { supersedesID?: string }).supersedesID === existingRole.id,
    )
    expect(replacement).toBeTruthy()
    expect((replacement as { data: { sourceDocumentID: string | null } }).data.sourceDocumentID).not.toBeNull()
  })

  it('writes source metadata only for attachments that contributed a saved item', () => {
    const draft = buildDossierDraft(PROPOSAL, { mode: 'create', name: 'Kelly Tsaur' }, [])
    // Default inclusion: role + employer (file-1) and the relationship (file-1).
    // The sensitive health fact (file-2) stays excluded — so no notes.docx source.
    const { plan, sources } = planFromDossierDraft(
      draft,
      { targetPerson: null, existingPeople: [], sources: SOURCES },
      NOW,
    )
    const sourceWrites = plan.filter((w) => w.collection === 'sources')
    expect(sourceWrites).toHaveLength(1)
    expect(sources[0].displayName).toBe('kelly-dossier.pdf')
    expect((sourceWrites[0] as { data: { rawFileRetained: boolean } }).data.rawFileRetained).toBe(false)
  })

  it('creates the person, facts, and relationship atomically for a new target', () => {
    const harbinder = person('Harbinder Raina')
    const draft = buildDossierDraft(PROPOSAL, { mode: 'create', name: 'Kelly Tsaur' }, [])
    const { plan, person: created } = planFromDossierDraft(
      draft,
      { targetPerson: null, existingPeople: [harbinder], sources: SOURCES },
      NOW,
    )
    expect(created.displayName).toBe('Kelly Tsaur')
    expect(created.roleTitle).toBe('Head of Payer/Provider Industry Vertical')
    const peopleSets = plan.filter((w) => w.collection === 'people' && w.op === 'set')
    // Only Kelly is created; Harbinder resolves to the existing record.
    expect(peopleSets).toHaveLength(1)
    expect(plan.filter((w) => w.collection === 'relationships')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'observations').length).toBeGreaterThanOrEqual(3)
    // Importing a dossier never creates an interaction.
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)
  })

  it('keep-resolutions write nothing for that fact', () => {
    const kelly = person('Kelly Tsaur')
    const existingRole = makeObservation(
      { subjectID: kelly.id, attribute: 'role', value: 'Director of Strategy' },
      new Date('2025-01-01T12:00:00'),
    )
    let draft = buildDossierDraft(PROPOSAL, { mode: 'existing', person: kelly }, [existingRole])
    draft = {
      ...draft,
      facts: draft.facts.map((f) => (f.conflict ? { ...f, conflict: { ...f.conflict, resolution: 'keep' as const } } : f)),
    }
    const { plan } = planFromDossierDraft(draft, { targetPerson: kelly, existingPeople: [kelly], sources: SOURCES }, NOW)
    expect(plan.some((w) => w.op === 'update' && w.collection === 'observations')).toBe(false)
    const values = plan
      .filter((w) => w.collection === 'observations')
      .map((w) => (w as { data: { attribute: string } }).data.attribute)
    expect(values).not.toContain('role')
  })

  it('counts included items for the save button', () => {
    const draft = buildDossierDraft(PROPOSAL, { mode: 'create', name: 'Kelly Tsaur' }, [])
    expect(includedCount(draft)).toBe(3) // role + employer + relationship
  })
})
