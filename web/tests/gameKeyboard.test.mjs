import test from 'node:test'
import assert from 'node:assert/strict'
import { GameKeyboard, validateKeyboardResponse } from '../src/lib/gameKeyboard.ts'

const tick = () => new Promise(resolve => setImmediate(resolve))
const owner = 'a'.repeat(32)

test('old generic success and malformed replies cannot enable Game mode', () => {
  for (const result of [null, {}, { ok: true }, { ok: true, active: true, lease_ms: 1500, sequence: -1 }]) {
    assert.throws(() => validateKeyboardResponse(result, 'acquire'), /keyboard_unavailable/)
  }
  assert.throws(() => validateKeyboardResponse({ error: 'keyboard_busy' }, 'acquire'), /keyboard_busy/)
  validateKeyboardResponse({ ok: true, active: true, lease_ms: 1500, sequence: 0 }, 'acquire')
  validateKeyboardResponse({ ok: true, active: false, lease_ms: 1500, sequence: 0 }, 'release')
  assert.throws(() => validateKeyboardResponse({ ok: true, active: false, lease_ms: 1500, sequence: 1 }, 'state'))
})

test('held combinations preserve press and release order without browser repeats', async () => {
  const sent = []
  const keyboard = new GameKeyboard(async body => { sent.push(body) }, () => {}, () => owner)
  try {
    await keyboard.start()
    await tick()
    keyboard.down(26, false)
    keyboard.down(4, false)
    keyboard.down(26, true)
    keyboard.up(26)
    keyboard.releaseKeys()
    await tick()
    const states = sent.filter(x => x.action === 'state')
    assert.deepEqual(states.map(x => x.keys), [[], [26], [4, 26], [4], []])
    assert.deepEqual(states.map(x => x.sequence), [1, 2, 3, 4, 5])
  } finally { keyboard.stop() }
  assert.deepEqual(sent.at(-1), { action: 'release', owner })
})

test('only one state request is in flight and short taps are not coalesced away', async () => {
  const sent = []
  let finish
  const keyboard = new GameKeyboard(body => {
    sent.push(body)
    return body.action === 'state' ? new Promise(resolve => { finish = resolve }) : Promise.resolve()
  }, () => {}, () => owner)
  try {
    await keyboard.start()
    keyboard.down(26, false)
    keyboard.up(26)
    assert.equal(sent.filter(x => x.action === 'state').length, 1)
    finish(); await tick()
    assert.deepEqual(sent.at(-1).keys, [26])
    finish(); await tick()
    assert.deepEqual(sent.at(-1).keys, [])
    finish(); await tick()
  } finally { keyboard.stop() }
})

test('a late acquisition after disabling is released, never activated', async () => {
  const sent = []
  let finish
  const keyboard = new GameKeyboard(body => {
    sent.push(body)
    return body.action === 'acquire' ? new Promise(resolve => { finish = resolve }) : Promise.resolve()
  }, () => {}, () => owner)
  const pending = keyboard.start()
  keyboard.stop()
  finish(); await pending
  assert.equal(keyboard.status.mode, 'text')
  assert.equal(sent.filter(x => x.action === 'state').length, 0)
  assert.equal(sent.at(-1).action, 'release')
})

test('failed state delivery clears keys and releases the lease', async () => {
  const sent = []
  const keyboard = new GameKeyboard(async body => {
    sent.push(body)
    if (body.action === 'state') throw new Error('keyboard_not_owned')
  }, () => {}, () => owner)
  await keyboard.start(); await tick()
  assert.equal(keyboard.status.mode, 'error')
  assert.equal(sent.at(-1).action, 'release')
  keyboard.down(26, false)
  assert.equal(sent.at(-1).action, 'release')
  keyboard.stop()
})

test('backpressure is bounded and stops rather than replaying unlimited stale input', async () => {
  let finish
  const sent = []
  const keyboard = new GameKeyboard(body => {
    sent.push(body)
    return body.action === 'state' ? new Promise(resolve => { finish = resolve }) : Promise.resolve()
  }, () => {}, () => owner)
  await keyboard.start()
  for (let i = 0; i < 20; i++) { keyboard.down(26, false); keyboard.up(26) }
  assert.equal(keyboard.status.error, 'keyboard_connection_too_slow')
  assert.equal(sent.at(-1).action, 'release')
  finish(); await tick()
  assert.equal(sent.filter(x => x.action === 'state').length, 1)
  keyboard.stop()
})
