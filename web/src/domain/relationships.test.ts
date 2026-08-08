import { describe, expect, it } from 'vitest'
import { FactAttributes } from './facts'
import {
  GROUP_TITLES,
  INVERSE,
  RELATIONSHIP_KINDS,
  SUGGESTED_ATTRIBUTES,
  genderedKind,
  groupOf,
  isSymmetric,
  kindLabel,
  possessivePhrase,
  relationshipPair,
} from './relationships'

describe('the inverse map', () => {
  it('is a total involution: every kind maps back to itself through its inverse', () => {
    for (const kind of RELATIONSHIP_KINDS) {
      expect(INVERSE[INVERSE[kind]]).toBe(kind)
    }
  })

  it('pairs the asymmetric kinds the way the world does', () => {
    expect(INVERSE.parent).toBe('child')
    expect(INVERSE.auntUncle).toBe('nieceNephew')
    expect(INVERSE.manager).toBe('directReport')
    expect(INVERSE.introducedBy).toBe('introduced')
    expect(INVERSE.petOwner).toBe('pet')
    expect(isSymmetric('partner')).toBe(true)
    expect(isSymmetric('unknown')).toBe(true)
    expect(isSymmetric('parent')).toBe(false)
  })
})

describe('the pair', () => {
  it('cross-links both halves, shares one creation instant, and never mirrors the label', () => {
    const now = new Date('2026-08-06T10:00:00')
    const [forward, backward] = relationshipPair({
      subjectID: 'maya',
      otherID: 'jack',
      kind: 'child',
      customLabel: '  son ',
      now,
    })

    expect(forward.subjectID).toBe('maya')
    expect(forward.otherID).toBe('jack')
    expect(forward.kind).toBe('child')
    expect(forward.customLabel).toBe('son')
    expect(backward.subjectID).toBe('jack')
    expect(backward.otherID).toBe('maya')
    expect(backward.kind).toBe('parent')
    expect(backward.customLabel).toBeNull()
    expect(forward.reciprocalID).toBe(backward.id)
    expect(backward.reciprocalID).toBe(forward.id)
    expect(forward.createdAt).toBe(backward.createdAt)
  })

  it('stores no label at all when the word is blank', () => {
    const [forward] = relationshipPair({
      subjectID: 'a',
      otherID: 'b',
      kind: 'friend',
      customLabel: '   ',
      now: new Date(),
    })
    expect(forward.customLabel).toBeNull()
  })

  it('refuses a self-relationship', () => {
    expect(() =>
      relationshipPair({ subjectID: 'a', otherID: 'a', kind: 'sibling', now: new Date() }),
    ).toThrow()
  })
})

describe('phrases and words', () => {
  it("prefers the user's word in the possessive phrase and falls back to the kind", () => {
    expect(possessivePhrase('Maya', 'child', 'son')).toBe("Maya's son")
    expect(possessivePhrase('Maya', 'child')).toBe("Maya's child")
    expect(possessivePhrase('Maya', 'child', '   ')).toBe("Maya's child")
    expect(possessivePhrase('Dana', 'directReport')).toBe("Dana's direct report")
    expect(kindLabel('householdMember')).toBe('household')
    expect(kindLabel('unknown')).toBe('unknown relationship')
  })

  it('maps only relationship words to kinds, never names', () => {
    expect(genderedKind('son')).toBe('child')
    expect(genderedKind('Wife')).toBe('partner')
    expect(genderedKind('co-worker')).toBe('colleague')
    expect(genderedKind('dog')).toBe('pet')
    expect(genderedKind('flatmate')).toBe('householdMember')
    expect(genderedKind('niece')).toBe('nieceNephew')
    expect(genderedKind('nephew')).toBe('nieceNephew')
    expect(genderedKind('aunt')).toBe('auntUncle')
    expect(genderedKind('Alice')).toBeNull()
  })
})

describe('suggestions and groups', () => {
  it('offers every kind a suggestion list ending in the open door', () => {
    for (const kind of RELATIONSHIP_KINDS) {
      const suggested = SUGGESTED_ATTRIBUTES[kind]
      expect(suggested.length).toBeGreaterThan(0)
      expect(suggested).toContain(FactAttributes.quickFact)
    }
    expect(SUGGESTED_ATTRIBUTES.child).toEqual([
      FactAttributes.observedAge,
      FactAttributes.schoolGrade,
      FactAttributes.school,
      FactAttributes.quickFact,
    ])
  })

  it('places every kind in a named group, closest first', () => {
    expect(groupOf('partner')).toBe('family')
    expect(groupOf('nieceNephew')).toBe('family')
    expect(groupOf('pet')).toBe('household')
    expect(groupOf('worksWith')).toBe('work')
    expect(groupOf('introducedBy')).toBe('other')
    expect(groupOf('unknown')).toBe('other')
    for (const kind of RELATIONSHIP_KINDS) {
      expect(GROUP_TITLES[groupOf(kind)]).toBeTruthy()
    }
  })
})
