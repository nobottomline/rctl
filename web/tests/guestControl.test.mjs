import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { stripTypeScriptTypes } from 'node:module'

let generation = 0
const moduleURL = (source) => `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`

async function environment(t, permissions = ['screen.view'], supported = true) {
  let cleanup = () => {}
  t.after(() => cleanup())
  const events = [], peers = [], sockets = [], reasons = []
  class Peer {
    constructor(config) { this.config = config; peers.push(this) }
    close() { events.push('peer-close') }
    setConfiguration() { throw new DOMException('Configuration is immutable', 'InvalidModificationError') }
    async setRemoteDescription(description) { this.remoteDescription = description }
    async createAnswer() { return { type: 'answer', sdp: 'synthetic-answer' } }
    async setLocalDescription(description) { this.localDescription = description }
    async addIceCandidate(candidate) { (this.candidates ||= []).push(candidate) }
  }
  class Socket {
    static OPEN = 1
    readyState = 1
    constructor(url) { this.url = url; sockets.push(this) }
    send(value) { events.push(['signal', JSON.parse(value)]) }
    close() { events.push('socket-close') }
  }
  const window = { setTimeout, setInterval, clearTimeout, clearInterval, RCTL_WEBRTC: 1,
    RCTL_GUEST_BOOTSTRAP: permissions ? { permissions, allow_direct: false } : null }
  if (supported) window.RTCPeerConnection = Peer
  const globals = { window, location: { protocol: 'https:', host: 'relay.example.invalid' },
    WebSocket: Socket, RTCPeerConnection: Peer, fetch: () => { throw new Error('Unexpected owner HTTP request') } }
  for (const [key, value] of Object.entries(globals)) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, { configurable: true, value })
    t.after(() => previous ? Object.defineProperty(globalThis, key, previous) : delete globalThis[key])
  }
  const source = async (name) => stripTypeScriptTypes(await readFile(new URL(`../src/lib/${name}.ts`, import.meta.url), 'utf8'))
  const paths = moduleURL(`${await source('rctl')}\n// test generation ${++generation}`)
  const playback = moduleURL(await source('macroPlayback'))
  const engineSource = (await source('engine')).replace("'./rctl'", JSON.stringify(paths)).replace("'./macroPlayback'", JSON.stringify(playback))
  const { ControlEngine } = await import(moduleURL(engineSource))
  const cameraSource = (await source('camera')).replace("'./rctl'", JSON.stringify(paths))
  const { CameraTransport } = await import(moduleURL(cameraSource))
  const routes = await import(paths)
  const video = { style: {}, srcObject: { privatePixels: true }, pause() { events.push('pause') },
    removeAttribute() {}, load() { events.push('video-clear') } }
  const canvas = { style: {}, width: 10, height: 10, getContext: () => ({ clearRect() { events.push('canvas-clear') } }) }
  const engine = new ControlEngine({}, canvas, video, { onEnded: (reason) => { events.push('ended'); reasons.push(reason) } })
  const camera = new CameraTransport(video)
  cleanup = () => { engine.stop(); camera.stop() }
  const ice = [{ urls: ['turn:turn.example.invalid:3478?transport=udp'], username: 'synthetic', credential: 'fixture' }]
  const ready = () => sockets.at(-1).onmessage({ data: JSON.stringify({ kind: 'ready', payload: ice }) })
  const start = async () => { engine.start(); if (supported) await ready() }
  return { engine, start, ready, ice, camera, routes, events, peers, sockets, video, reasons }
}

test('guest startup preserves relay-only ICE when ready supplies TURN and requests no owner APIs', async t => {
  const { engine, peers, sockets } = await environment(t)
  engine.start()
  assert.equal(sockets[0].url, 'wss://relay.example.invalid/api/guest/signal')
  assert.equal(peers.length, 0, 'wait for ICE before allocating a peer')
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'ready', payload: [{ urls: 'turn:turn.example.invalid' }] }) })
  assert.equal(peers[0].config.iceTransportPolicy, 'relay')
})

test('guest socket loss clears pixels, closes the peer and never starts an HTTP fallback', async t => {
  const { engine, start, peers, sockets, video, events } = await environment(t)
  await start()
  sockets[0].onclose({ code: 1000 })
  assert.equal(video.srcObject, null)
  assert.ok(events.includes('canvas-clear') && events.includes('peer-close') && events.includes('ended'))
  engine.scheduleReconnect()
  assert.equal(peers.length, 1)
  assert.equal(sockets.length, 1)
  peers[0].ontrack({ streams: [{ latePrivatePixels: true }] })
  assert.equal(video.srcObject, null)
})

test('guest teardown retains a safe transport failure reason without signaling payloads', async t => {
  const { engine, start, peers, reasons, video } = await environment(t)
  await start()
  peers[0].connectionState = 'failed'
  peers[0].onconnectionstatechange()
  assert.deepEqual(reasons, ['The WebRTC connection failed.'])
  assert.equal(video.srcObject, null)
})

test('ICE completion and stale candidate callbacks never send invalid signaling', async t => {
  const { engine, start, peers, events } = await environment(t)
  await start()
  const candidate = peers[0].onicecandidate
  candidate({ candidate: null })
  candidate({ candidate: { candidate: '', sdpMid: null } })
  assert.equal(events.filter(event => Array.isArray(event)).length, 0)
  candidate({ candidate: { candidate: 'candidate:fixture', sdpMid: 'video' } })
  assert.deepEqual(events.filter(event => Array.isArray(event)), [['signal', {
    kind: 'candidate', payload: { candidate: 'candidate:fixture', mid: 'video' },
  }]])
  engine.stop()
  candidate({ candidate: { candidate: 'candidate:late', sdpMid: 'video' } })
  assert.equal(events.filter(event => Array.isArray(event)).length, 1)
})

test('unsupported guest WebRTC ends access without legacy streaming', async t => {
  const { engine, start, events, sockets } = await environment(t, ['screen.view'], false)
  await start()
  assert.equal(sockets.length, 0)
  assert.ok(events.includes('ended'))
})

test('guest policy refuses owner routes, unauthorized channels and independent device buttons', async t => {
  const { engine, start, routes, peers, events } = await environment(t, ['screen.view', 'input.button.home'])
  assert.throws(() => routes.rctlPath('/v1/config'))
  assert.throws(() => routes.fileDownloadURL('/private/file'))
  assert.throws(() => routes.termWS(80, 24))
  await start()
  const sent = []
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 0, send: (s) => sent.push(JSON.parse(s)) } })
  engine.sysPress('home'); engine.sysPress('lock'); engine.key(4, 2); engine.springboard(1)
  await new Promise(resolve => setTimeout(resolve, 90))
  assert.deepEqual(sent, [{ t: 'k', pg: 12, u: 64, d: 1 }, { t: 'k', pg: 12, u: 64, d: 0 }])
  peers[0].ondatachannel({ channel: { label: 'files', close() { events.push('denied-channel-close') } } })
  assert.ok(events.includes('denied-channel-close') && events.includes('ended'))
})

test('guest input backpressure disconnects instead of accumulating delayed commands', async t => {
  const { engine, start, peers, events } = await environment(t, ['screen.view', 'input.keyboard'])
  await start()
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 20000,
    send() { assert.fail('Input must not be queued under backpressure') } } })
  engine.key(4, 1)
  assert.ok(events.includes('ended') && events.includes('peer-close'))
})

test('a delayed guest button release cannot cross into a replacement channel', async t => {
  const { engine, start, peers } = await environment(t, ['screen.view', 'input.button.home'])
  await start()
  const sent = []
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 0,
    send: (s) => sent.push(JSON.parse(s)) } })
  engine.sysPress('home')
  engine.stop()
  engine.control = { send() { assert.fail('Old release reached a replacement channel') } }
  await new Promise(resolve => setTimeout(resolve, 90))
  assert.equal(sent.length, 1)
})


test('TURN configuration is supplied at construction when dynamic changes are unsupported', async t => {
  const { engine, start, ice, peers, sockets } = await environment(t)
  await start()
  assert.deepEqual(peers[0].config.iceServers, ice)
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'offer', payload: { sdp: 'synthetic-offer' } }) })
  assert.equal(peers[0].remoteDescription.sdp, 'synthetic-offer')
  assert.equal(peers.length, 1)
})

test('a guest offer before ICE readiness fails closed', async t => {
  const { engine, sockets, peers, reasons } = await environment(t)
  engine.start()
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'offer', payload: { sdp: 'synthetic-offer' } }) })
  assert.equal(peers.length, 0)
  assert.match(reasons[0], /did not configure/)
})

test('device-local offer without relay ready remains supported', async t => {
  const { engine, sockets, peers } = await environment(t, null)
  engine.startWebRTC('ws://device.example.invalid/ws/signal')
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'candidate', payload: { candidate: 'candidate:fixture', mid: '0' } }) })
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'offer', payload: { sdp: 'synthetic-offer' } }) })
  assert.deepEqual(peers[0].config.iceServers, [])
  assert.equal(peers[0].candidates.length, 1)
})

test('stopping before readiness does not create a late peer', async t => {
  const { engine, ready, peers } = await environment(t)
  engine.start()
  engine.stop()
  await ready()
  assert.equal(peers.length, 0)
})

test('camera receives TURN at construction and ignores readiness after stop', async t => {
  const { camera, ready, ice, peers } = await environment(t)
  camera.start()
  assert.equal(peers.length, 0)
  await ready()
  assert.deepEqual(peers[0].config.iceServers, ice)
  assert.equal(peers[0].config.iceTransportPolicy, 'relay')
  camera.stop()
  await ready()
  assert.equal(peers.length, 1)
})

test('device-local camera negotiates without relay readiness', async t => {
  const { camera, sockets, peers } = await environment(t, null)
  camera.start()
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'offer', payload: { sdp: 'synthetic-camera-offer' } }) })
  assert.equal(peers.length, 1)
  assert.equal(peers[0].remoteDescription.sdp, 'synthetic-camera-offer')
  assert.deepEqual(peers[0].config.iceServers, [])
})

test('guest camera cannot negotiate before receiving ICE policy', async t => {
  const { camera, sockets, peers, video } = await environment(t)
  camera.start()
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'offer', payload: { sdp: 'synthetic-camera-offer' } }) })
  assert.equal(peers.length, 0)
  assert.equal(video.srcObject, null)
})
