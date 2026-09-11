import test from 'node:test'
import assert from 'node:assert/strict'
import { MicTalk } from '../src/lib/mic.ts'

function deferred() {
  let resolve
  let reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function setup(t) {
  const track = new EventTarget()
  track.readyState = 'live'
  track.stops = 0
  track.stop = () => { track.stops++; track.readyState = 'ended' }
  const stream = { getAudioTracks: () => [track], getTracks: () => [track] }
  const encoders = []
  const contexts = []
  const media = { calls: 0, getUserMedia: async () => { media.calls++; return stream } }
  class Encoder {
    static supported = true
    static async isConfigSupported() { return { supported: this.supported } }
    constructor(callbacks) { this.callbacks = callbacks; this.state = 'unconfigured'; encoders.push(this) }
    configure() { this.state = 'configured' }
    close() { this.state = 'closed' }
    encode() {}
  }
  class Context {
    constructor() { this.sampleRate = 48000; this.state = 'suspended'; contexts.push(this) }
    createScriptProcessor() { this.node = { connect() {} }; return this.node }
    createGain() { return { gain: { value: 1 }, connect() {} } }
    createMediaStreamSource() { return { connect() {}, disconnect() {} } }
    async resume() { this.state = 'running' }
    async suspend() { this.state = 'suspended' }
    async close() { this.state = 'closed' }
  }
  for (const [key, value] of Object.entries({ navigator: { mediaDevices: media }, window: { AudioContext: Context }, AudioEncoder: Encoder, AudioData: class { close() {} } })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
    t.after(() => descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key])
  }
  const channel = () => ({ readyState: 'open', sends: 0, send() { this.sends++ } })
  const mic = new MicTalk()
  const states = []
  const errors = []
  mic.onState = value => states.push(value)
  mic.onError = value => errors.push(value)
  t.after(() => mic.stop())
  mic.attach(channel())
  return { mic, track, stream, media, Encoder, Context, contexts, encoders, channel, states, errors }
}

test('a delayed old channel close cannot stop a new Talk session', async t => {
  const { mic, channel, track, states } = setup(t)
  const old = channel()
  mic.attach(old)
  const newChannel = channel()
  mic.attach(newChannel)
  assert.equal(await mic.start(), true)
  old.onclose()
  assert.equal(states.at(-1), true)
  assert.equal(track.stops, 0)
  assert.equal(mic.ready(), true)
})

test('cancel while microphone permission is pending releases late tracks', async t => {
  const { mic, media, stream, track, states, encoders } = setup(t)
  const permission = deferred()
  media.getUserMedia = () => permission.promise
  const started = mic.start()
  mic.stop()
  permission.resolve(stream)
  assert.equal(await started, false)
  assert.equal(track.stops, 1)
  assert.equal(encoders.length, 0)
  assert.ok(!states.includes(true))
})

test('replacing a channel cancels pending capture instead of moving it silently', async t => {
  const { mic, media, stream, track, channel, errors } = setup(t)
  const permission = deferred()
  media.getUserMedia = () => permission.promise
  const started = mic.start()
  mic.attach(channel())
  permission.resolve(stream)
  assert.equal(await started, false)
  assert.equal(track.stops, 1)
  assert.match(errors.at(-1), /connection changed/)
})

test('repeated clicks cannot create overlapping microphone requests', async t => {
  const { mic, media, stream } = setup(t)
  const permission = deferred()
  let calls = 0
  media.getUserMedia = () => { calls++; return permission.promise }
  const first = mic.start()
  assert.equal(await mic.start(), false)
  permission.resolve(stream)
  assert.equal(await first, true)
  assert.equal(calls, 1)
})

test('late encoder callbacks cannot send to or stop a replacement session', async t => {
  const { mic, channel, encoders, media, states } = setup(t)
  assert.equal(await mic.start(), true)
  const old = encoders[0]
  mic.stop()
  const track = new EventTarget()
  track.readyState = 'live'
  track.stop = () => {}
  media.getUserMedia = async () => ({ getAudioTracks: () => [track], getTracks: () => [track] })
  const next = channel()
  mic.attach(next)
  assert.equal(await mic.start(), true)
  old.callbacks.error(new Error('late codec callback'))
  old.callbacks.output({ byteLength: 4, copyTo() {} })
  assert.equal(states.at(-1), true)
  assert.equal(next.sends, 0)
})

test('unsupported Opus is explained and capture is released', async t => {
  const { mic, Encoder, track, errors } = setup(t)
  Encoder.supported = false
  assert.equal(await mic.start(), false)
  assert.equal(track.stops, 1)
  assert.match(errors.at(-1), /does not support Opus/)
})

test('permission denial exposes a safe actionable error', async t => {
  const { mic, media, errors } = setup(t)
  media.getUserMedia = async () => { throw new DOMException('private platform detail', 'NotAllowedError') }
  assert.equal(await mic.start(), false)
  assert.match(errors.at(-1), /permission was denied/)
  assert.ok(!errors.at(-1).includes('private'))
})

test('active channel loss stops tracks and reports why Talk ended', async t => {
  const { mic, track, channel, errors } = setup(t)
  const ch = channel()
  mic.attach(ch)
  assert.equal(await mic.start(), true)
  ch.readyState = 'closed'
  ch.onclose()
  assert.equal(track.stops, 1)
  assert.match(errors.at(-1), /connection closed/)
})

test('microphone removal stops Talk without an unhandled rejection', async t => {
  const { mic, track, errors } = setup(t)
  assert.equal(await mic.start(), true)
  track.dispatchEvent(new Event('ended'))
  assert.equal(track.stops, 1)
  assert.match(errors.at(-1), /disconnected/)
})

test('graph setup failure releases the acquired microphone', async t => {
  const { mic, Context, track, errors } = setup(t)
  Context.prototype.createMediaStreamSource = () => { throw new Error('graph failed') }
  assert.equal(await mic.start(), false)
  assert.equal(track.stops, 1)
  assert.match(errors.at(-1), /configure microphone/)
})

test('cancellation during AudioContext resume cannot reactivate Talk', async t => {
  const { mic, Context, track, contexts, encoders } = setup(t)
  const resume = deferred()
  Context.prototype.resume = async function () { await resume.promise; this.state = 'running' }
  const started = mic.start()
  await Promise.resolve()
  mic.stop()
  resume.resolve()
  assert.equal(await started, false)
  assert.equal(track.stops, 1)
  assert.equal(encoders.length, 0)
  assert.equal(contexts[0].state, 'suspended')
})

test('asynchronous encoder errors stop capture and explain the failure', async t => {
  const { mic, encoders, track, states, errors } = setup(t)
  assert.equal(await mic.start(), true)
  encoders[0].callbacks.error(new DOMException('platform detail', 'EncodingError'))
  assert.equal(track.stops, 1)
  assert.equal(encoders[0].state, 'closed')
  assert.equal(states.at(-1), false)
  assert.match(errors.at(-1), /Opus microphone encoding failed/)
})
