import test from 'node:test'
import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
const source = await readFile(new URL('../../relay/internal/relay/guest_landing.js', import.meta.url), 'utf8')

function landing({ hidden = false, prerender = false, secret = 's'.repeat(43), current = null, failure, ackFailure } = {}) {
  const elements = Object.fromEntries(['join', 'error', 'heading', 'status', 'resume'].map(id => [id, { hidden: id === 'join' || id === 'resume', textContent: '', disabled: false }]))
  const events = new Map(), requests = [], redirects = [], history = []
  let claims = 0, acks = 0
  const document = { visibilityState: hidden ? 'hidden' : 'visible', prerendering: prerender,
    getElementById: id => elements[id], addEventListener: (event, callback) => events.set(event, callback), removeEventListener: event => events.delete(event) }
  const context = { document, AbortController, setTimeout, clearTimeout,
    location: { hash: secret ? '#' + secret : '', pathname: '/share/disposable-invitation', replace: path => redirects.push(path) },
    history: { replaceState: (_state, _title, path) => history.push(path) },
    fetch: async (path, options) => {
      requests.push({ path, body: options.body && JSON.parse(options.body) })
      if (path === '/api/guest/session') return { status: current ? 200 : 401, ok: Boolean(current), json: async () => current }
      if (path === '/api/guest/claim' && ++claims === 1 && failure) throw new Error(failure)
      if (path === '/api/guest/claim/ack' && ++acks === 1 && ackFailure) throw new Error(ackFailure)
      return { status: 200, ok: true, json: async () => ({ ok: true }) }
    } }
  vm.runInNewContext(source, context)
  const settle = async () => { for (let i = 0; i < 12; i++) await new Promise(resolve => setImmediate(resolve)) }
  return { elements, requests, redirects, history, document, events, settle }
}

test('a visible invitation connects automatically and removes its fragment before any request', async () => {
  const page = landing(); await page.settle()
  assert.deepEqual(page.history, ['/share/disposable-invitation'])
  assert.deepEqual(page.requests.map(r => r.path), ['/api/guest/session', '/api/guest/prepare', '/api/guest/claim', '/api/guest/claim/ack'])
  assert.deepEqual(page.redirects, ['/guest/control'])
  assert.equal(page.elements.join.hidden, true)
})

test('hidden and prerendered invitation pages defer all network work until activation', async () => {
  for (const settings of [{ hidden: true }, { prerender: true }]) {
    const page = landing(settings); await page.settle(); assert.equal(page.requests.length, 0)
    page.document.visibilityState = 'visible'; page.document.prerendering = false
    const activate = page.events.values().next().value; activate(); activate(); await page.settle()
    assert.equal(page.requests.filter(r => r.path === '/api/guest/claim').length, 1)
    assert.deepEqual(page.redirects, ['/guest/control'])
  }
})

test('lost claim responses retain the original binding for retry instead of preparing another claim', async () => {
  const page = landing({ failure: 'network_failed' }); await page.settle()
  assert.equal(page.elements.join.hidden, false)
  page.elements.join.onclick(); await page.settle()
  assert.equal(page.requests.filter(r => r.path === '/api/guest/prepare').length, 1)
  assert.equal(page.requests.filter(r => r.path === '/api/guest/claim').length, 2)
  assert.deepEqual(page.redirects, ['/guest/control'])
})

test('failed acknowledgement retries only acknowledgement without rotating the established cookie', async () => {
  const page = landing({ ackFailure: 'network_failed' }); await page.settle()
  page.elements.join.onclick(); await page.settle()
  assert.equal(page.requests.filter(r => r.path === '/api/guest/claim').length, 1)
  assert.equal(page.requests.filter(r => r.path === '/api/guest/claim/ack').length, 2)
  assert.deepEqual(page.redirects, ['/guest/control'])
})

test('opening the same invitation with an active cookie resumes without consuming it again', async () => {
  const page = landing({ current: { grant_id: 'disposable-invitation' } }); await page.settle()
  assert.equal(page.requests.some(r => r.path === '/api/guest/claim'), false)
  assert.deepEqual(page.redirects, ['/guest/control'])
})

test('a different active session stays intact and offers an explicit return link', async () => {
  const page = landing({ current: { grant_id: 'other-disposable-invitation' } }); await page.settle()
  assert.equal(page.requests.length, 1)
  assert.equal(page.redirects.length, 0)
  assert.equal(page.elements.resume.hidden, false)
  assert.match(page.elements.error.textContent, /another session/)
})

test('a missing fragment cannot claim anything and an existing cookie can still resume', async () => {
  const page = landing({ secret: '' }); await page.settle()
  assert.equal(page.requests.length, 1); assert.equal(page.elements.join.hidden, true); assert.equal(page.elements.resume.hidden, false)
  const active = landing({ secret: '', current: { grant_id: 'disposable-invitation' } }); await active.settle()
  assert.deepEqual(active.redirects, ['/guest/control'])
})
