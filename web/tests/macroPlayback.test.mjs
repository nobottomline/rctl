import test from 'node:test'
import assert from 'node:assert/strict'
import { MacroPlayback, macroScript } from '../src/lib/macroPlayback.ts'

test('export preserves raw touch phases and event timing', () => {
  assert.deepEqual(macroScript([
    { t: 10, k: 't', p: 0, i: 1, x: .2, y: .3 },
    { t: 60, k: 't', p: 2, i: 1, x: .4, y: .3 },
    { t: 60, k: 'k', u: 4, d: 2 },
  ]), { actions: [
    { type: 'wait', ms: 10 }, { type: 'input', phase: 0, id: 1, x: .2, y: .3 },
    { type: 'wait', ms: 50 }, { type: 'input', phase: 2, id: 1, x: .4, y: .3 },
    { type: 'input_key', p: 7, u: 4, d: 2 },
  ] })
})

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

test('pause freezes timeline between gestures and resumes without replaying events', async () => {
  const player = new MacroPlayback(), sent = [], states = []
  const done = player.play([{ t: 0, k: 'k', u: 4, d: 2 }, { t: 120, k: 'k', u: 5, d: 2 }],
    (e) => { sent.push(e); if (sent.length === 1) player.pause() }, (s) => states.push(s))
  await sleep(160)
  assert.equal(sent.length, 1)
  assert.ok(states.includes('play-paused'))
  player.resume()
  await done
  assert.deepEqual(sent.map(e => e.u), [4, 5])
  assert.equal(states.at(-1), 'idle')
})

test('pause completes an active touch before freezing', async () => {
  const player = new MacroPlayback(), sent = [], states = []
  const done = player.play([
    { t: 0, k: 't', i: 0, p: 0, x: .2, y: .3 },
    { t: 40, k: 't', i: 0, p: 2, x: .3, y: .3 },
    { t: 100, k: 'k', u: 4, d: 2 },
  ], e => { sent.push(e); if (sent.length === 1) player.pause() }, s => states.push(s))
  await sleep(150)
  assert.deepEqual(sent.map(e => e.p), [0, 2])
  assert.ok(states.includes('pausing'))
  assert.ok(states.includes('play-paused'))
  player.stop()
  await done
  assert.equal(sent.length, 2)
})

test('stop releases held inputs and cancels pending events', async () => {
  const player = new MacroPlayback(), sent = []
  const done = player.play([{ t: 0, k: 'k', u: 225, d: 1 }, { t: 1000, k: 'k', u: 4, d: 2 }],
    e => sent.push(e), () => {})
  player.stop()
  await done
  assert.deepEqual(sent.map(e => [e.u, e.d]), [[225, 1], [225, 0]])
})
