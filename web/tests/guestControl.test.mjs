import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { stripTypeScriptTypes } from 'node:module'

let generation = 0
const moduleURL = (source) => `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`

async function environment(t, permissions = ['screen.view'], supported = true) {
  const events = [], peers = [], sockets = []
  class Peer {
    constructor(config) { this.config = config; peers.push(this) }
    close() { events.push('peer-close') }
    setConfiguration(config) { this.config = config }
  }
  class Socket {
    static OPEN = 1
    readyState = 1
    constructor(url) { this.url = url; sockets.push(this) }
    close() { events.push('socket-close') }
  }
  const window = { setTimeout, setInterval, RCTL_WEBRTC: 1,
    RCTL_GUEST_BOOTSTRAP: { permissions, allow_direct: false } }
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
  const routes = await import(paths)
  const video = { style: {}, srcObject: { privatePixels: true }, pause() { events.push('pause') },
    removeAttribute() {}, load() { events.push('video-clear') } }
  const canvas = { style: {}, width: 10, height: 10, getContext: () => ({ clearRect() { events.push('canvas-clear') } }) }
  const engine = new ControlEngine({}, canvas, video, { onEnded: () => events.push('ended') })
  t.after(() => engine.stop())
  return { engine, routes, events, peers, sockets, video }
}

test('guest startup preserves relay-only ICE when ready supplies TURN and requests no owner APIs', async t => {
  const { engine, peers, sockets } = await environment(t)
  engine.start()
  assert.equal(sockets[0].url, 'wss://relay.example.invalid/api/guest/signal')
  assert.equal(peers[0].config.iceTransportPolicy, 'relay')
  await sockets[0].onmessage({ data: JSON.stringify({ kind: 'ready', payload: [{ urls: 'turn:turn.example.invalid' }] }) })
  assert.equal(peers[0].config.iceTransportPolicy, 'relay')
})

test('guest socket loss clears pixels, closes the peer and never starts an HTTP fallback', async t => {
  const { engine, peers, sockets, video, events } = await environment(t)
  engine.start()
  sockets[0].onclose()
  assert.equal(video.srcObject, null)
  assert.ok(events.includes('canvas-clear') && events.includes('peer-close') && events.includes('ended'))
  engine.scheduleReconnect()
  assert.equal(peers.length, 1)
  assert.equal(sockets.length, 1)
  peers[0].ontrack({ streams: [{ latePrivatePixels: true }] })
  assert.equal(video.srcObject, null)
})

test('unsupported guest WebRTC ends access without legacy streaming', async t => {
  const { engine, events, sockets } = await environment(t, ['screen.view'], false)
  engine.start()
  assert.equal(sockets.length, 0)
  assert.ok(events.includes('ended'))
})

test('guest policy refuses owner routes, unauthorized channels and independent device buttons', async t => {
  const { engine, routes, peers, events } = await environment(t, ['screen.view', 'input.button.home'])
  assert.throws(() => routes.rctlPath('/v1/config'))
  assert.throws(() => routes.fileDownloadURL('/private/file'))
  assert.throws(() => routes.termWS(80, 24))
  engine.start()
  const sent = []
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 0, send: (s) => sent.push(JSON.parse(s)) } })
  engine.sysPress('home'); engine.sysPress('lock'); engine.key(4, 2); engine.springboard(1)
  await new Promise(resolve => setTimeout(resolve, 90))
  assert.deepEqual(sent, [{ t: 'k', pg: 12, u: 64, d: 1 }, { t: 'k', pg: 12, u: 64, d: 0 }])
  peers[0].ondatachannel({ channel: { label: 'files', close() { events.push('denied-channel-close') } } })
  assert.ok(events.includes('denied-channel-close') && events.includes('ended'))
})

test('guest input backpressure disconnects instead of accumulating delayed commands', async t => {
  const { engine, peers, events } = await environment(t, ['screen.view', 'input.keyboard'])
  engine.start()
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 20000,
    send() { assert.fail('Input must not be queued under backpressure') } } })
  engine.key(4, 1)
  assert.ok(events.includes('ended') && events.includes('peer-close'))
})

test('a delayed guest button release cannot cross into a replacement channel', async t => {
  const { engine, peers } = await environment(t, ['screen.view', 'input.button.home'])
  engine.start()
  const sent = []
  peers[0].ondatachannel({ channel: { label: 'control', readyState: 'open', bufferedAmount: 0,
    send: (s) => sent.push(JSON.parse(s)) } })
  engine.sysPress('home')
  engine.stop()
  engine.control = { send() { assert.fail('Old release reached a replacement channel') } }
  await new Promise(resolve => setTimeout(resolve, 90))
  assert.equal(sent.length, 1)
})
