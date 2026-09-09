import test from 'node:test'
import assert from 'node:assert/strict'
import { copyText } from '../src/lib/clipboard.ts'

function environment(t, clipboard, fallbackResult) {
  const events = []
  class Element { focus() { events.push('restore-focus') } }
  const field = { style: {}, focus() {}, select() {}, remove() { events.push('remove') } }
  const selection = { rangeCount: 0, removeAllRanges() {}, addRange() {} }
  const values = {
    navigator: { clipboard }, HTMLElement: Element,
    document: {
      activeElement: new Element(), getSelection: () => selection,
      createElement: () => field, body: { appendChild() {} },
      execCommand(command) { assert.equal(command, 'copy'); events.push('fallback'); return fallbackResult },
    },
  }
  for (const [key, value] of Object.entries(values)) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, { configurable: true, value })
    t.after(() => {
      if (previous) Object.defineProperty(globalThis, key, previous)
      else delete globalThis[key]
    })
  }
  return { events, field }
}

test('native text clipboard success does not use the legacy fallback', async t => {
  const { events } = environment(t, { writeText: async text => assert.equal(text, 'test') }, false)
  assert.equal(await copyText('test'), true)
  assert.deepEqual(events, [])
})

test('HTTP fallback copies text and restores focus without leaving a textarea', async t => {
  const { events, field } = environment(t, undefined, true)
  assert.equal(await copyText('test'), true)
  assert.equal(field.value, 'test')
  assert.deepEqual(events, ['fallback', 'remove', 'restore-focus'])
})

test('clipboard denial and a failed fallback never report success', async t => {
  const { events } = environment(t, { writeText: async () => { throw Error('denied') } }, false)
  assert.equal(await copyText('test'), false)
  assert.deepEqual(events, ['fallback', 'remove', 'restore-focus'])
})
