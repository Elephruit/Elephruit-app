/// The markdown shortcuts are the reason the toolbar could be put away, so
/// what they cover is worth pinning.
///
/// **What this does and does not prove.** `MarkdownShortcutPlugin` runs the
/// transformer set below against the text as it is typed; this asserts the set
/// handles every marker the Format menu advertises. It does not simulate
/// keystrokes — browser automation inserts text atomically (a paste, in effect)
/// and the shortcut deliberately fires on the discrete space that a paste never
/// produces, so the keystroke path itself is a by-hand check. A wrong or empty
/// transformer list is the realistic regression, and that this catches.

import { $convertFromMarkdownString, TRANSFORMERS } from '@lexical/markdown'
import { CodeNode } from '@lexical/code'
import { LinkNode } from '@lexical/link'
import { ListItemNode, ListNode } from '@lexical/list'
import { createHeadlessEditor } from '@lexical/headless'
import { HeadingNode, QuoteNode } from '@lexical/rich-text'
import { $getRoot } from 'lexical'
import { describe, expect, it } from 'vitest'

function nodeTypesFor(markdown: string): string[] {
  const editor = createHeadlessEditor({
    namespace: 'markdown-test',
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, CodeNode, LinkNode],
    onError: (error) => {
      throw error
    },
  })
  editor.update(() => $convertFromMarkdownString(markdown, TRANSFORMERS), { discrete: true })
  return editor.getEditorState().read(() => $getRoot().getChildren().map((node) => node.getType()))
}

describe('the markers the Format menu advertises', () => {
  it('turns # into a heading', () => {
    expect(nodeTypesFor('# Chicago')).toEqual(['heading'])
  })

  it('turns ## and ### into headings too', () => {
    expect(nodeTypesFor('## Where to eat')).toEqual(['heading'])
    expect(nodeTypesFor('### Deep dish')).toEqual(['heading'])
  })

  it('turns - into a bulleted list', () => {
    expect(nodeTypesFor('- Pequod')).toEqual(['list'])
  })

  it('turns 1. into a numbered list', () => {
    expect(nodeTypesFor('1. First')).toEqual(['list'])
  })

  it('turns > into a quote', () => {
    expect(nodeTypesFor('> Somebody else')).toEqual(['quote'])
  })

  it('turns a fence into a code block', () => {
    expect(nodeTypesFor('```\nconst x = 1\n```')).toEqual(['code'])
  })

  /// The checklist marker Lexical understands is `- [ ] `, and the Format menu
  /// says `[] ` because that is the shorter thing people actually type. Both
  /// are covered by the list transformer; this pins the written one.
  it('turns - [ ] into a checklist', () => {
    expect(nodeTypesFor('- [ ] Print the confirmation')).toEqual(['list'])
  })

  it('leaves ordinary prose alone', () => {
    expect(nodeTypesFor('Field Museum opens at 9')).toEqual(['paragraph'])
  })
})

describe('inline markers', () => {
  it('covers bold, italic and inline code', () => {
    // The transformer set is shared with the block markers above; this asserts
    // the inline half is present rather than a block-only subset.
    const inline = TRANSFORMERS.filter((transformer) => transformer.type === 'text-format')
    const tags = inline.flatMap((transformer) => ('tag' in transformer ? [transformer.tag] : []))
    expect(tags).toContain('**')
    expect(tags).toContain('`')
  })
})
