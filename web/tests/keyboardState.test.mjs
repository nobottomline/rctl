import test from 'node:test'
import assert from 'node:assert/strict'
import { KeyboardState } from '../src/lib/keyboardState.ts'

test('text remains atomic including browser repeats', () => {
  const sent = [], keyboard = new KeyboardState((...event) => sent.push(event))
  keyboard.down(26, false)
  keyboard.down(26, true)
  keyboard.up(26)
  assert.deepEqual(sent, [[26, 2], [26, 2]])
})

test('modifiers release once after focus loss and ignore stale keyup', () => {
  const sent = [], keyboard = new KeyboardState((...event) => sent.push(event))
  keyboard.down(0xe3, false)
  keyboard.down(0xe3, false)
  keyboard.down(0xe3, true)
  keyboard.down(0xe1, false)
  keyboard.release()
  keyboard.release()
  assert.equal(keyboard.up(0xe3), false)
  assert.deepEqual(sent, [[0xe3, 1], [0xe1, 1], [0xe3, 0], [0xe1, 0]])
  keyboard.down(0xe3, false)
  assert.equal(keyboard.up(0xe3), true)
  assert.deepEqual(sent.slice(-2), [[0xe3, 1], [0xe3, 0]])
})

test('keyup cannot release a modifier owned by another client', () => {
  const sent = [], keyboard = new KeyboardState((...event) => sent.push(event))
  assert.equal(keyboard.up(0xe3), false)
  keyboard.down(0xe1, true)
  keyboard.release()
  assert.deepEqual(sent, [])
})
