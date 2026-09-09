import test from 'node:test'
import assert from 'node:assert/strict'
import { GamePointer, pointerCaptureUnavailable } from '../src/lib/gamePointer.ts'

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
class Channel extends EventTarget {
  label = 'pointer'
  readyState = 'open'
  bufferedAmount = 0
  sent = []
  held = false
  reply(body, extra = {}) {
    this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify({ id: body.id,
      ok: true, pointer_version: 1, lease_ms: 1500, active: body.action !== 'release', sequence: body.sequence || 0, ...extra }) }))
  }
  send(text) {
    const body = JSON.parse(text); this.sent.push(body)
    if (!this.held) queueMicrotask(() => this.reply(body))
  }
}
function setup() {
  const channel = new Channel()
  const motion = new Channel(); motion.label = 'pointer-motion'
  const pointer = new GamePointer(() => {})
  pointer.attach(channel)
  pointer.attach(motion)
  return { channel, motion, pointer }
}
test('relative movement coalesces and button order survives short clicks', async () => {
  const { channel, motion, pointer } = setup()
  try {
    await pointer.start()
    pointer.move(3, -2); pointer.move(4, 1)
    pointer.button(0, true); pointer.button(2, true); pointer.button(0, false); pointer.button(2, false)
    await tick()
    const states = channel.sent.filter(x => x.action === 'state')
    assert.deepEqual(states.map(x => [x.dx, x.dy, x.buttons]), [[0, 0, 1], [0, 0, 3], [0, 0, 2], [0, 0, 0]])
    assert.deepEqual(states.map(x => x.sequence), [1, 2, 3, 4])
    assert.deepEqual(motion.sent.map(x => [x.action, x.dx, x.dy, x.buttons]), [['move', 7, -1, undefined]])
  } finally { pointer.detach() }
})
test('movement has no touch fallback without a negotiated pointer channel', async () => {
  const pointer = new GamePointer(() => {})
  await pointer.start()
  assert.equal(pointer.status.mode, 'error')
  assert.equal(pointer.status.available, false)
  pointer.detach()
})
test('both channels are required and may arrive in either order', async () => {
  const pointer = new GamePointer(() => {})
  const motion = new Channel(); motion.label = 'pointer-motion'
  pointer.attach(motion)
  assert.equal(pointer.status.available, false)
  const channel = new Channel()
  pointer.attach(channel)
  assert.equal(pointer.status.available, true)
  await pointer.start()
  assert.equal(pointer.status.mode, 'active')
  motion.readyState = 'closed'; motion.dispatchEvent(new Event('close'))
  assert.equal(pointer.status.available, false)
  assert.equal(pointer.status.mode, 'error')
  assert.equal(channel.sent.at(-1).action, 'release')
  pointer.detach()
})
test('late acquire after stopping cannot regain capture', async () => {
  const { channel, pointer } = setup()
  channel.held = true
  const start = pointer.start()
  const acquire = channel.sent[0]
  pointer.stop()
  channel.reply(acquire)
  await start
  assert.equal(pointer.status.mode, 'idle')
  assert.equal(channel.sent.at(-1).action, 'release')
  assert.equal(channel.sent.filter(x => x.action === 'state').length, 0)
  pointer.detach()
})
test('wrong response sequence disables capture and releases the owner', async () => {
  const { channel, pointer } = setup()
  try {
    await pointer.start(); channel.held = true
    pointer.button(1, true)
    const state = channel.sent.at(-1)
    assert.equal(state.buttons, 4)
    channel.reply(state, { sequence: 123 })
    await tick()
    assert.equal(pointer.status.mode, 'error')
    assert.equal(channel.sent.at(-1).action, 'release')
  } finally { pointer.detach() }
})
test('motion backpressure drops deltas without losing reliable button releases', async () => {
  const { channel, motion, pointer } = setup()
  try {
    await pointer.start(); channel.held = true
    pointer.button(0, true)
    pointer.button(2, true)
    const state = channel.sent.at(-1)
    motion.bufferedAmount = 3000
    pointer.move(40, 0)
    pointer.button(0, false)
    await tick(180)
    channel.reply(state)
    await tick(40)
    const next = channel.sent.at(-1)
    assert.equal(pointer.status.mode, 'active')
    assert.equal(next.dx, 0)
    assert.equal(next.buttons, 2) // left released, right remains held
    assert.equal(motion.sent.length, 0)
    channel.reply(next)
    await tick()
    motion.bufferedAmount = 0
    pointer.move(3, 0)
    await tick(40)
    assert.equal(motion.sent.at(-1).dx, 3)
    pointer.stop()
    channel.held = false; channel.bufferedAmount = 3000
    await pointer.start()
    assert.equal(pointer.status.mode, 'error')
  } finally { pointer.detach() }
})
test('motion continues while both reliable acknowledgements are delayed', async () => {
  const { channel, motion, pointer } = setup()
  try {
    await pointer.start(); channel.held = true
    pointer.button(0, true); pointer.button(0, false)
    for (let i = 0; i < 6; i++) { pointer.move(2, -1); await tick(20) }
    assert.equal(channel.sent.filter(x => x.action === 'state').length, 2)
    assert.equal(motion.sent.length, 6)
    assert.equal(pointer.status.mode, 'active')
    assert.deepEqual(motion.sent.map(x => x.sequence), [1, 2, 3, 4, 5, 6])
  } finally { pointer.detach() }
})
test('idle lease refresh does not wait for the previous response', async () => {
  const { channel, pointer } = setup()
  try {
    await pointer.start(); channel.held = true
    await tick(950)
    const states = channel.sent.filter(x => x.action === 'state')
    assert.equal(states.length, 2)
    assert.equal(pointer.status.mode, 'active')
    channel.reply(states[0]); channel.reply(states[1])
    await tick(40)
    assert.equal(pointer.status.mode, 'active')
    assert.equal(channel.sent.filter(x => x.action === 'state').length, 3)
  } finally { pointer.detach() }
})
test('capture availability explains every disabled precondition', () => {
  assert.match(pointerCaptureUnavailable(false, 'game', true, false), /browser/)
  assert.match(pointerCaptureUnavailable(true, 'game', true, true), /recording/)
  assert.match(pointerCaptureUnavailable(false, 'connecting', true, true), /connecting/)
  assert.match(pointerCaptureUnavailable(false, 'error', true, true), /unavailable/)
  assert.match(pointerCaptureUnavailable(false, 'text', true, true), /Game/)
  assert.match(pointerCaptureUnavailable(false, 'game', false, true), /WebRTC/)
  assert.equal(pointerCaptureUnavailable(false, 'game', true, true), undefined)
})
test('disconnect clears pending requests and never resumes on a new channel', async () => {
  const { channel, pointer } = setup()
  await pointer.start()
  pointer.button(0, true)
  await tick()
  channel.readyState = 'closed'; channel.dispatchEvent(new Event('close'))
  assert.equal(pointer.status.mode, 'error')
  assert.equal(pointer.status.available, false)
  const replacement = new Channel()
  pointer.attach(replacement)
  assert.equal(pointer.status.mode, 'idle')
  assert.deepEqual(replacement.sent, [])
  pointer.detach()
})
