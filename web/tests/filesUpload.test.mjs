import test from 'node:test'
import assert from 'node:assert/strict'
import { FileTransfer } from '../src/lib/files.ts'

// Virtualized time: setTimeout advances a fake clock and runs an optional
// per-tick hook, so 15s ack deadlines and backpressure polling resolve fast
// and deterministically.
let clock = 0
let onTimer = () => {}
const realSetTimeout = globalThis.setTimeout
const realClearTimeout = globalThis.clearTimeout
const realDateNow = Date.now
let virtualTimers = []
function virtualTime() {
  clock = 0
  onTimer = () => {}
  virtualTimers = []
  Date.now = () => clock
  const w = /** @type {Record<string, unknown>} */ (globalThis)
  w.setTimeout = (cb, delay) => {
    const timer = {
      cancelled: false,
      fire() {
        if (timer.cancelled) return
        timer.cancelled = true
        clock += delay || 0
        try { onTimer() } finally { cb() }
      },
    }
    virtualTimers.push(timer)
    queueMicrotask(() => timer.fire())
    return timer
  }
  w.clearTimeout = (handle) => {
    if (handle && typeof handle === 'object' && 'cancelled' in handle) {
      handle.cancelled = true
    }
  }
}
function realTime() {
  Date.now = realDateNow
  globalThis.setTimeout = realSetTimeout
  globalThis.clearTimeout = realClearTimeout
}

function stubChannel() {
  return {
    binaryType: '',
    readyState: 'open',
    bufferedAmount: 0,
    sent: [],
    onmessage: null,
    onclose: null,
    send(data) { this.sent.push(typeof data === 'string' ? JSON.parse(data) : 'chunk') },
    deliver(json) { this.onmessage?.({ data: JSON.stringify(json) }) },
    close() { this.readyState = 'closed'; this.onclose?.() },
  }
}

function sampleFile(size = 4) {
  return new File([new Uint8Array(size)], 'sample.bin')
}

// Drive the clock until the (minCount+1)-th message of `kind` is on the wire:
// helpers are count-based so consecutive uploads on one channel wait for
// THEIR message, not an earlier one's.
async function waitFor(ch, kind, minCount = 0) {
  for (let i = 0; i < 500; i++) {
    if (ch.sent.filter((m) => m.op === kind).length > minCount) return
    await new Promise((r) => setTimeout(r, 0))
  }
  assert.fail(`'${kind}' #${minCount + 1} never reached the wire`)
}

async function untilEof(ch, minCount = 0) {
  await waitFor(ch, 'put_eof', minCount)
}

async function untilPut(ch, minCount = 0) {
  await waitFor(ch, 'put', minCount)
}

// P2P uploads exist ONLY in strict mode (the files.transfer_ids capability):
// every test attaches the channel and negotiates before uploading.
function strictTransfer(ch) {
  const transfer = new FileTransfer()
  transfer.attach(ch)
  transfer.negotiate(ch, { features: ['files.transfer_ids'] })
  return transfer
}

test('a legacy daemon upload never starts: HTTP is selected instead', async () => {
  virtualTime()
  try {
    const transfer = new FileTransfer()
    const ch = stubChannel()
    transfer.attach(ch)   // capabilities pending: legacy-tolerant default
    // An id-less ack is unattributable in principle (the old daemon routes
    // replies through its global newest channel), so no P2P put is ever
    // sent: the caller falls back to HTTP.
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'none')
    assert.deepEqual(ch.sent, [])
    assert.equal(transfer.lastOutcome, 'none')
    // The same after an explicit failed negotiation.
    transfer.negotiate(ch, null)
    assert.equal(await transfer.upload(sampleFile(), '/b'), 'none')
    assert.deepEqual(ch.sent, [])
  } finally { realTime() }
})

test('an upload awaits the in-flight negotiation instead of racing it', async () => {
  // REAL time: the negotiation race uses a bounded real timer, and virtual
  // time would resolve the bound before the decision lands.
  realTime()
  try {
    const ch = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch)
    // The negotiation is in flight when the pick lands: upload() waits for
    // it, then proceeds over P2P.
    let settle
    const pending = new Promise((r) => { settle = r })
    transfer.beginNegotiation(ch, pending)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 20))
    assert.deepEqual(ch.sent, [])   // nothing sent while undecided
    settle({ features: ['files.transfer_ids'] })
    await untilPut(ch)
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await upload, 'confirmed')
  } finally { realTime() }
})

test('the transport-agnostic upload slot serializes HTTP fallbacks', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    assert.equal(transfer.claimUploadSlot(), true)
    assert.equal(transfer.claimUploadSlot(), false)   // one slot at a time
    transfer.releaseUploadSlot()
    assert.equal(transfer.claimUploadSlot(), true)
    // The P2P path's slot (this.ul) also blocks the HTTP claim.
    transfer.releaseUploadSlot()
    const a = transfer.upload(sampleFile(), '/a')
    await untilPut(ch)
    assert.equal(transfer.claimUploadSlot(), false)
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await a, 'confirmed')
    assert.equal(transfer.claimUploadSlot(), true)
  } finally { realTime() }
})

test('the id-carrying put_ok confirms exactly its own attempt', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    await new Promise((r) => setTimeout(r, 0))   // chunk + eof on the wire
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await upload, 'confirmed')
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put', 'chunk', 'put_eof'])
  } finally { realTime() }
})

test('a put_ok for a timed-out attempt can never confirm a different attempt', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    // Attempt A gets no acknowledgement: it times out unconfirmed.
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'unconfirmed')
    // Attempt B starts on the same channel; A's late put_ok (A's id) must
    // not complete B. Prove it: close the channel afterwards — if B had been
    // confirmed it would return 'confirmed', but a still-pending B fails
    // unconfirmed.
    const b = transfer.upload(sampleFile(), '/b')
    const lateId = ch.sent[0].id          // the timed-out attempt's id
    ch.deliver({ op: 'put_ok', bytes: 4, id: lateId })
    ch.close()
    assert.equal(await b, 'unconfirmed')
  } finally { realTime() }
})

test('unmatched id-carrying replies change nothing', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    let doneCalls = 0
    transfer.onDone = () => { doneCalls++ }
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    await new Promise((r) => setTimeout(r, 0))   // chunk + eof on the wire
    ch.deliver({ op: 'put_ok', bytes: 4, id: 'u999' })   // not this attempt's id
    assert.equal(doneCalls, 0)
    ch.deliver({ op: 'err', msg: 'write failed', id: 'u999' })
    ch.deliver({ op: 'err', msg: 'protected', id: 'd999' })   // download domain: no fetch pending
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await upload, 'confirmed')
    assert.equal(doneCalls, 1)
  } finally { realTime() }
})

test('a byte-count mismatch on the id-bound answer is a definitive refusal', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(4), '/a')
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    await new Promise((r) => setTimeout(r, 0))   // chunk + eof on the wire
    ch.deliver({ op: 'put_ok', bytes: 7, id: ch.sent[0].id })
    assert.equal(await upload, 'refused')
    assert.equal(transfer.lastRefused, true)
    assert.equal(transfer.lastUnconfirmed, false)
  } finally { realTime() }
})

test('a channel stuck closing during backpressure exits without throwing and stays unconfirmed', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    ch.bufferedAmount = 1024 * 1024
    onTimer = () => { ch.readyState = 'closing' }
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'unconfirmed')
    assert.equal(transfer.lastUnconfirmed, true)
    // Strict mode: no put_started ever arrived and the channel is closing,
    // so nothing but the put ever hit the wire (the cleanup cancel requires
    // an open channel; the daemon reaps the dead one).
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put'])
  } finally { realTime() }
})

test('onclose during backpressure fails the attempt without a TypeError', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    ch.bufferedAmount = 1024 * 1024
    onTimer = () => { ch.readyState = 'closed'; ch.onclose?.() }
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'unconfirmed')
    assert.equal(transfer.lastUnconfirmed, true)
  } finally { realTime() }
})

test('a replacement channel never receives a stale attempt\'s bytes or eof', async () => {
  virtualTime()
  try {
    const ch1 = stubChannel()
    const transfer = strictTransfer(ch1)
    ch1.bufferedAmount = 1024 * 1024
    onTimer = () => { ch1.readyState = 'closed'; ch1.onclose?.() }
    const a = transfer.upload(sampleFile(256 * 1024), '/a')
    assert.equal(await a, 'unconfirmed')
    const ch2 = stubChannel()
    transfer.attach(ch2)
    transfer.negotiate(ch2, { features: ['files.transfer_ids'] })
    const b = transfer.upload(sampleFile(), '/b')
    const staleId = ch1.sent[0].id        // attempt A's id, never sent on ch2
    await new Promise((r) => setTimeout(r, 0))
    ch2.deliver({ op: 'put_started', id: ch2.sent[0].id })
    await untilEof(ch2)
    ch2.deliver({ op: 'put_ok', bytes: 4, id: ch2.sent[0].id })
    assert.equal(await b, 'confirmed')
    assert.deepEqual(ch2.sent.map((m) => m.op ?? m), ['put', 'chunk', 'put_eof'])
    assert.notEqual(ch2.sent[0].id, staleId)
  } finally { realTime() }
})

test('an upload already in flight refuses the HTTP fallback for a second pick', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const a = transfer.upload(sampleFile(), '/same.bin')   // stays pending
    // A second pick for the same destination while A is in flight: an HTTP
    // re-push would truncate the target the daemon is writing, so the
    // fallback must be refused.
    assert.equal(await transfer.upload(sampleFile(), '/same.bin'), 'busy')
    assert.equal(transfer.lastUnconfirmed, true)
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    await new Promise((r) => setTimeout(r, 0))   // chunk + eof on the wire
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await a, 'confirmed')
  } finally { realTime() }
})

test('a closing channel with an active upload refuses the second pick without flag reset', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const a = transfer.upload(sampleFile(), '/same.bin')   // pending
    // The second pick runs while the channel is still open but A's slot
    // makes it busy; only AFTER A's full handshake does the channel close.
    assert.equal(await transfer.upload(sampleFile(), '/same.bin'), 'busy')
    assert.equal(transfer.lastUnconfirmed, true)   // NOT reset: no HTTP fallback
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await a, 'confirmed')
    ch.readyState = 'closing'
  } finally { realTime() }
})

test('strict mode: chunks flow only after put_started, then confirm normally', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    // Before acceptance nothing but the put may be on the wire.
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put'])
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    await new Promise((r) => setTimeout(r, 0))   // chunk + eof on the wire
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put', 'chunk', 'put_eof'])
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await upload, 'confirmed')
    assert.equal(ch.sent.some((m) => m.op === 'cancel'), false)
  } finally { realTime() }
})

test('a refused put never writes chunks', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'err', msg: 'transfer in progress', id: ch.sent[0].id })
    assert.equal(await upload, 'refused')
    assert.equal(transfer.lastRefused, true)
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put', 'cancel'])
  } finally { realTime() }
})

test('a foreign put_started does not start this attempt', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    const myId = ch.sent[0].id
    ch.deliver({ op: 'put_started', id: 'u999' })   // not ours
    await new Promise((r) => setTimeout(r, 0))
    assert.deepEqual(ch.sent.map((m) => m.op ?? m), ['put'])   // still waiting
    ch.deliver({ op: 'put_started', id: myId })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 4, id: myId })
    assert.equal(await upload, 'confirmed')
  } finally { realTime() }
})

test('a chunk failure after acceptance releases the daemon reservation', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    let calls = 0
    const realSend = ch.send.bind(ch)
    ch.send = (data) => {
      calls++
      if (calls === 3) throw new Error('dead channel')   // the second chunk fails
      realSend(data)
    }
    const upload = transfer.upload(sampleFile(65537), '/a')   // two chunks
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await new Promise((r) => setTimeout(r, 0))   // first chunk flows
    assert.equal(await upload, 'unconfirmed')
    assert.equal(transfer.lastUnconfirmed, true)
    const cancel = ch.sent.find((m) => m.op === 'cancel')
    assert.ok(cancel)
    assert.equal(cancel.id, ch.sent[0].id)   // names its own attempt
    assert.equal(ch.sent.some((m) => m.op === 'put_eof'), false)   // no eof after the failure
  } finally { realTime() }
})

test('the pre-start cleanup cancel names its own attempt id', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(), '/a')
    await new Promise((r) => setTimeout(r, 0))
    const bid = ch.sent[0].id
    ch.deliver({ op: 'err', msg: 'transfer in progress', id: bid })
    await upload
    const cancel = ch.sent.find((m) => m.op === 'cancel')
    assert.ok(cancel)
    assert.equal(cancel.id, bid)
  } finally { realTime() }
})

test('a throwing send fails the attempt unconfirmed instead of rejecting out of the panel', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    let calls = 0
    ch.send = (data) => {
      calls++
      if (calls >= 2) throw new Error('dead channel')
      ch.sent.push(JSON.parse(data))
    }
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'unconfirmed')
    assert.equal(transfer.lastUnconfirmed, true)
  } finally { realTime() }
})

test('a cancel send that throws on an open channel is retried until enqueued', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    transfer.attach = undefined   // unused here
    let cancelAttempts = 0
    const realSend = ch.send.bind(ch)
    ch.send = (data) => {
      const msg = typeof data === 'string' ? JSON.parse(data) : null
      if (msg?.op === 'cancel' && cancelAttempts++ < 2) {
        ch.bufferedAmount = 1024 * 1024   // send queue full: the enqueue throws
        throw new Error('send queue full')
      }
      ch.bufferedAmount = 0
      realSend(data)
    }
    // The handshake never completes (no put_started): the cleanup must
    // release the reservation even though the first two cancel enqueues
    // throw.
    assert.equal(await transfer.upload(sampleFile(), '/a'), 'unconfirmed')
    const cancel = ch.sent.find((m) => m.op === 'cancel')
    assert.ok(cancel, 'the cancel must eventually be enqueued')
    assert.equal(cancel.id, ch.sent[0].id)
  } finally { realTime() }
})

test('a close after an explicit refusal keeps exactly one outcome flag', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const a = transfer.upload(sampleFile(), '/a')
    const busy = transfer.upload(sampleFile(), '/b')   // busy pick: unconfirmed flag
    assert.equal(await busy, 'busy')
    ch.deliver({ op: 'err', msg: 'transfer in progress', id: ch.sent[0].id })
    ch.close()
    assert.equal(await a, 'refused')
    assert.equal(transfer.lastRefused, true)
    assert.equal(transfer.lastUnconfirmed, false)   // the explicit verdict won
  } finally { realTime() }
})

test('a replacement wakes the waiting pick the moment its strict decision lands', async () => {
  // REAL time: virtual timers fire eagerly regardless of delay, which would
  // expire the 10s bound before the replacement's decision lands.
  realTime()
  try {
    const ch1 = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch1)
    let settleOld
    transfer.beginNegotiation(ch1, new Promise((r) => { settleOld = r }))
    const older = transfer.upload(sampleFile(32), '/a')   // oversized, waits
    const ch2 = stubChannel()
    transfer.attach(ch2)
    let settleNew
    transfer.beginNegotiation(ch2, new Promise((r) => { settleNew = r }))
    // Still undecided: nothing may be on the wire (the pick is waiting for
    // the CURRENT channel's negotiation, not sitting out a bound).
    await new Promise((r) => setTimeout(r, 20))
    assert.deepEqual(ch1.sent, [])
    assert.deepEqual(ch2.sent, [])
    // The replacement's decision lands early (well before the 10s bound):
    // the pick must wake PROMPTLY — well under the 10s budget — and go P2P
    // on the new channel.
    const startedAt = Date.now()
    settleNew({ features: ['files.transfer_ids'] })
    await untilPut(ch2)
    const waited = Date.now() - startedAt
    assert.ok(waited < 9000, `the pick waited ${waited}ms past the ready decision`)
    ch2.deliver({ op: 'put_started', id: ch2.sent[0].id })
    await untilEof(ch2)
    ch2.deliver({ op: 'put_ok', bytes: 32, id: ch2.sent[0].id })
    assert.equal(await older, 'confirmed')
  } finally { realTime() }
})

test('a timed-out pick\'s wait never discards a still-pending decision', async () => {
  // REAL time: the per-pick 10s budget must actually elapse (virtual timers
  // fire eagerly, which would end every wait at once).
  realTime()
  try {
    const ch = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch)
    const globals = /** @type {Record<string, unknown>} */ (globalThis)
    globals.RCTL_RELAY_TUNNEL_MAX_BODY = 16
    let settle
    transfer.beginNegotiation(ch, new Promise((r) => { settle = r }))
    const first = transfer.upload(sampleFile(32), '/a')   // the 10s budget expires
    await new Promise((r) => setTimeout(r, 10100))
    assert.equal(await first, 'unsupported')
    // The decision is STILL pending: a later pick re-arms on it (a fresh
    // 10s budget) instead of instant-unsupported.
    const second = transfer.upload(sampleFile(32), '/b')
    await new Promise((r) => setTimeout(r, 50))
    settle({ features: ['files.transfer_ids'] })
    await untilPut(ch)
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 32, id: ch.sent[0].id })
    assert.equal(await second, 'confirmed')
    delete globals.RCTL_RELAY_TUNNEL_MAX_BODY
  } finally { realTime() }
})

test('a replacement\'s pending negotiation decides a newer pick; the older pick cannot', async () => {
  // REAL time: the chunk reads are real async work that virtual microtask
  // ticks do not pump deterministically.
  realTime()
  try {
    const ch1 = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch1)
    const globals = /** @type {Record<string, unknown>} */ (globalThis)
    globals.RCTL_RELAY_TUNNEL_MAX_BODY = 16
    let settleOld
    const oldPromise = new Promise((r) => { settleOld = r })
    transfer.beginNegotiation(ch1, oldPromise)
    const older = transfer.upload(sampleFile(32), '/a')   // oversized, awaits
    // The replacement installs ITS negotiation synchronously, before the
    // stale decision lands: the loop must follow it, not decide off ch1.
    const ch2 = stubChannel()
    transfer.attach(ch2)
    let settleNew
    const newPromise = new Promise((r) => { settleNew = r })
    transfer.beginNegotiation(ch2, newPromise)
    assert.deepEqual(ch1.sent, [])
    assert.deepEqual(ch2.sent, [])
    // The stale decision lands; the loop follows the replacement instead of
    // deciding the transport off ch1.
    settleOld(null)
    // The NEW decision (strict) governs: the oversized file goes P2P on ch2.
    settleNew({ features: ['files.transfer_ids'] })
    await untilPut(ch2)
    ch2.deliver({ op: 'put_started', id: ch2.sent[0].id })
    await untilEof(ch2)
    ch2.deliver({ op: 'put_ok', bytes: 32, id: ch2.sent[0].id })
    const outcome = await older
    assert.equal(outcome, 'confirmed')
    // sanity: the channel stays usable for a second transfer
    const second = transfer.upload(sampleFile(4), '/x')
    await untilPut(ch2, 1)   // the SECOND put
    ch2.deliver({ op: 'put_started', id: ch2.sent.filter((m) => m.op === 'put')[1].id })
    await untilEof(ch2, 1)
    ch2.deliver({ op: 'put_ok', bytes: 4, id: ch2.sent.filter((m) => m.op === 'put')[1].id })
    assert.equal(await second, 'confirmed')
    delete globals.RCTL_RELAY_TUNNEL_MAX_BODY
  } finally { realTime() }
})

test('a published zero body cap rejects every nonempty HTTP fallback', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch)
    const globals = /** @type {Record<string, unknown>} */ (globalThis)
    globals.RCTL_RELAY_TUNNEL_MAX_BODY = 0
    assert.equal(await transfer.upload(sampleFile(4), '/a'), 'unsupported')
    delete globals.RCTL_RELAY_TUNNEL_MAX_BODY
  } finally { realTime() }
})

test('a byte-less put_ok is refused, not confirmed', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const upload = transfer.upload(sampleFile(4), '/a')
    await new Promise((r) => setTimeout(r, 0))
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', id: ch.sent[0].id })   // no bytes field
    assert.equal(await upload, 'refused')
  } finally { realTime() }
})

test('an older unsupported pick cannot overwrite the newest pick\'s banner', async () => {
  // REAL time: virtual timers fire eagerly, which would expire the bound
  // before the negotiation settles.
  realTime()
  try {
    const ch = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch)
    const statuses = []
    transfer.onStatus = (s) => statuses.push(s.text)
    const globals = /** @type {Record<string, unknown>} */ (globalThis)
    globals.RCTL_RELAY_TUNNEL_MAX_BODY = 0
    let settle
    transfer.beginNegotiation(ch, new Promise((r) => { settle = r }))
    // The older pick parks on the negotiation; the zero published cap makes
    // it oversized, so its wake WOULD publish a 'caps uploads' verdict.
    const older = transfer.upload(sampleFile(4), '/a')
    // The newest pick starts while the older is parked and takes the entry
    // busy check (the HTTP push owns the slot): its banner is the
    // distinguishable 'upload busy' verdict, so the test can tell WHICH
    // pick's publication survived the epoch gate.
    assert.equal(transfer.claimUploadSlot(), true)
    const newest = transfer.upload(sampleFile(4), '/b')
    await new Promise((r) => setTimeout(r, 20))
    assert.deepEqual(statuses, ['⚠ upload busy'])
    // The older pick is STILL pending (decided by the verdict, not a timer):
    // race it against an already-resolved sentinel.
    assert.equal(await Promise.race([older, Promise.resolve('pending')]), 'pending')
    // The negotiation settles well inside the 10s budget: measure the
    // resolution latency across the awaits themselves.
    const startedAt = Date.now()
    settle(null)
    assert.equal(await newest, 'busy')        // the newest pick's own verdict
    assert.equal(await older, 'unsupported')  // decided promptly
    const waited = Date.now() - startedAt
    assert.ok(waited < 9000, `the picks waited ${waited}ms past the ready decision`)
    // The older pick's late 'caps uploads' publication must NEVER surface:
    // the newest pick owns the banner, so the only published status is its
    // 'upload busy' verdict. A mutation that lets the older publish (or
    // drops the newest's) changes this exact list.
    assert.deepEqual(statuses, ['⚠ upload busy'])
    delete globals.RCTL_RELAY_TUNNEL_MAX_BODY
  } finally { realTime() }
})

test('HTTP fallback during a replacement: P2P starts only after the push ends', async () => {
  // REAL time. The strict channel dies mid-handshake; the HTTP fallback
  // claims the slot; when the replacement channel negotiates strict, the
  // P2P pick must wait for the push to finish, then go P2P.
  realTime()
  try {
    const ch1 = stubChannel()
    const transfer = strictTransfer(ch1)
    const a = transfer.upload(sampleFile(4), '/a')   // pending on ch1
    ch1.close()                                      // lost channel
    assert.equal(await a, 'unconfirmed')             // ch1 died with the write pending
    // The HTTP fallback is chosen EXPLICITLY (the user retries): it claims
    // the slot and pushes.
    assert.equal(transfer.claimUploadSlot(), true)   // the push owns the slot
    const ch2 = stubChannel()
    transfer.attach(ch2)
    transfer.negotiate(ch2, { features: ['files.transfer_ids'] })
    // A P2P pick during the push refuses immediately (the caller retries):
    // it must never slip a put past the running push.
    const b = transfer.upload(sampleFile(4), '/b')
    await new Promise((r) => setTimeout(r, 20))
    assert.equal(await b, 'busy')
    assert.deepEqual(ch2.sent, [])                   // no put while HTTP owns the slot
    transfer.releaseUploadSlot()                     // the push completes
    // After the push ends, a fresh pick goes P2P.
    const c = transfer.upload(sampleFile(4), '/c')
    await untilPut(ch2)
    ch2.deliver({ op: 'put_started', id: ch2.sent[0].id })
    await untilEof(ch2)
    ch2.deliver({ op: 'put_ok', bytes: 4, id: ch2.sent[0].id })
    assert.equal(await c, 'confirmed')
  } finally { realTime() }
})

test('an oversized file on a relayed legacy connection is unsupported, even after the channel dies', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const globals = /** @type {Record<string, unknown>} */ (globalThis)
    globals.RCTL_RELAY_TUNNEL_MAX_BODY = 16
    const a = transfer.upload(sampleFile(32), '/a')   // oversized, strict P2P pending
    ch.close()                                        // channel lost
    assert.equal(await a, 'unconfirmed')
    // The lost channel takes the HTTP-eligible exit: the relay cap applies
    // THERE too — an oversized file must not blind-push a 413.
    assert.equal(await transfer.upload(sampleFile(32), '/b'), 'unsupported')
    assert.equal(transfer.lastOutcome, 'unsupported')
    delete globals.RCTL_RELAY_TUNNEL_MAX_BODY
    assert.equal(await transfer.upload(sampleFile(32), '/c'), 'none')   // no cap: HTTP stays
  } finally { realTime() }
})

test('a settling attempt releases only its own slot', async () => {
  virtualTime()
  try {
    const ch1 = stubChannel()
    const transfer = strictTransfer(ch1)
    const a = transfer.upload(sampleFile(4), '/a')   // A holds the slot, ack pending
    ch1.close()                                       // A fails via onclose
    const ch2 = stubChannel()
    transfer.attach(ch2)
    transfer.negotiate(ch2, { features: ['files.transfer_ids'] })
    const b = transfer.upload(sampleFile(4), '/b')    // B claims the slot
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(await a, 'unconfirmed')              // A settles NOW
    // A's terminal must not release B's slot: C's pick must be refused as
    // busy, not sent as a second put into B's channel.
    const c = transfer.upload(sampleFile(4), '/c')
    assert.equal(await c, 'busy')
    assert.equal(ch2.sent.filter((m) => m.op === 'put').length, 1)
    ch2.deliver({ op: 'put_started', id: ch2.sent[0].id })
    await untilEof(ch2)
    ch2.deliver({ op: 'put_ok', bytes: 4, id: ch2.sent[0].id })
    assert.equal(await b, 'confirmed')
  } finally { realTime() }
})

test('two picks awaiting the same negotiation serialize; the HTTP slot blocks P2P mid-await', async () => {
  // REAL time: both picks genuinely suspend on the negotiation, and the HTTP
  // slot is acquired WHILE they wait (not before upload() runs).
  realTime()
  try {
    const ch = stubChannel()
    const transfer = new FileTransfer()
    transfer.attach(ch)
    let settle
    transfer.beginNegotiation(ch, new Promise((r) => { settle = r }))
    const a = transfer.upload(sampleFile(), '/a')   // suspends on the decision
    const b = transfer.upload(sampleFile(), '/b')   // suspends too
    await new Promise((r) => setTimeout(r, 20))
    assert.deepEqual(ch.sent, [])   // nothing sent while undecided
    // Both picks are STILL pending (decided by the verdict, not a timer):
    // race each against an already-resolved sentinel.
    assert.equal(await Promise.race([a, Promise.resolve('pending')]), 'pending')
    assert.equal(await Promise.race([b, Promise.resolve('pending')]), 'pending')
    // The HTTP slot is acquired WHILE both picks are parked: neither may
    // slip a put past the running push.
    assert.equal(transfer.claimUploadSlot(), true)
    // The decision lands well inside the 10s budget: measure the resolution
    // latency across the awaits themselves, not a sleep.
    const startedAt = Date.now()
    settle({ features: ['files.transfer_ids'] })
    assert.equal(await a, 'busy')
    assert.equal(await b, 'busy')
    const waited = Date.now() - startedAt
    assert.ok(waited < 9000, `the picks waited ${waited}ms past the ready decision`)
    assert.deepEqual(ch.sent, [])
    transfer.releaseUploadSlot()
    // After the push ends, a fresh pick goes P2P.
    const c = transfer.upload(sampleFile(), '/c')
    await untilPut(ch)
    ch.deliver({ op: 'put_started', id: ch.sent[0].id })
    await untilEof(ch)
    ch.deliver({ op: 'put_ok', bytes: 4, id: ch.sent[0].id })
    assert.equal(await c, 'confirmed')
  } finally { realTime() }
})

test('an older attempt\'s late status never overwrites the newer pick\'s banner', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const statuses = []
    transfer.onStatus = (s) => statuses.push(s.text)
    const a = transfer.upload(sampleFile(4), '/a')
    await new Promise((r) => setTimeout(r, 0))   // A sent everything
    ch.deliver({ op: 'err', msg: 'transfer in progress', id: ch.sent[0].id })
    // A newer pick owns the banner from here on (it starts a fresh attempt
    // after the refusal released the slot).
    const b = transfer.upload(sampleFile(4), '/b')
    await new Promise((r) => setTimeout(r, 0))
    const before = statuses.length
    assert.equal(await a, 'refused')   // A settles now
    assert.equal(statuses.length, before, 'A\'s late status was dropped')
    assert.equal(await b, 'unconfirmed')   // B never got an ack
  } finally { realTime() }
})

// ---- downloads (fetch) — unchanged semantics -----------------------------

test('a download error reply rejects the pending fetch by its own id', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const fetchPromise = transfer.fetch('/protected.bin')
    const getId = ch.sent[0].id
    assert.match(getId, /^d\d+$/)
    ch.deliver({ op: 'err', msg: 'protected', id: getId })
    await assert.rejects(fetchPromise, /protected/)
  } finally { realTime() }
})

test('a fetch error only rejects its own fetch; a later fetch is unaffected', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const first = transfer.fetch('/a.bin')
    const firstId = ch.sent[0].id
    ch.deliver({ op: 'err', msg: 'protected', id: firstId })
    await assert.rejects(first, /protected/)
    const second = transfer.fetch('/b.bin')
    const secondId = ch.sent.at(-1).id
    assert.notEqual(secondId, firstId)
    ch.deliver({ op: 'err', msg: 'protected', id: firstId })   // the OLD fetch's id again
    ch.deliver({ op: 'get_meta', name: 'b.bin', size: 4, id: secondId })
    ch.deliver({ op: 'get_eof', id: secondId })
    assert.deepEqual(await second, new Blob([]))
  } finally { realTime() }
})

test('a cancelled get_eof is a failed download, not a partial success', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const pending = transfer.fetch('/recording.bin')
    ch.deliver({ op: 'get_meta', name: 'recording.bin', size: 100 })
    ch.deliver({ op: 'get_eof', cancelled: true })
    await assert.rejects(pending, /download cancelled/)
  } finally { realTime() }
})

test('a channel close rejects a pending fetch instead of leaving it hanging', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const pending = transfer.fetch('/x.bin')
    ch.close()
    await assert.rejects(pending, /files channel closed/)
  } finally { realTime() }
})

test('a replacement channel rejects the previous channel\'s pending fetch', async () => {
  virtualTime()
  try {
    const ch1 = stubChannel()
    const transfer = strictTransfer(ch1)
    const pending = transfer.fetch('/image.bin')
    transfer.attach(stubChannel())   // reconnect replaced the channel
    await assert.rejects(pending, /files channel replaced/)
  } finally { realTime() }
})

test('a replacement channel accepts a fresh fetch immediately', async () => {
  virtualTime()
  try {
    const ch1 = stubChannel()
    const transfer = strictTransfer(ch1)
    const oldFetch = transfer.fetch('/old.bin')
    const ch2 = stubChannel()
    transfer.attach(ch2)
    transfer.negotiate(ch2, { features: ['files.transfer_ids'] })
    await assert.rejects(oldFetch, /files channel replaced/)
    const fresh = transfer.fetch('/new.bin')   // must NOT be rejected as busy
    ch2.deliver({ op: 'get_meta', name: 'new.bin', size: 0, id: ch2.sent[0].id })
    ch2.deliver({ op: 'get_eof', id: ch2.sent[0].id })
    assert.deepEqual(await fresh, new Blob([]))
  } finally { realTime() }
})

test('a throwing get send releases the fetch slot for the next file', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    let fail = true
    ch.send = (data) => {
      if (fail) throw new Error('send failed')
      ch.sent.push(JSON.parse(data))
    }
    await assert.rejects(transfer.fetch('/a.bin'), /send failed/)
    fail = false
    const second = transfer.fetch('/b.bin')   // must not be wedged by the last one
    ch.deliver({ op: 'get_meta', name: 'b.bin', size: 0, id: ch.sent[0].id })
    ch.deliver({ op: 'get_eof', id: ch.sent[0].id })
    assert.deepEqual(await second, new Blob([]))
  } finally { realTime() }
})

test('a stale get_eof cannot complete a newer fetch', async () => {
  virtualTime()
  try {
    const ch = stubChannel()
    const transfer = strictTransfer(ch)
    const first = transfer.fetch('/a.bin')
    const firstId = ch.sent[0].id
    ch.deliver({ op: 'err', msg: 'protected', id: firstId })
    await assert.rejects(first, /protected/)
    const second = transfer.fetch('/b.bin')
    const secondId = ch.sent.at(-1).id
    assert.notEqual(secondId, firstId)
    ch.deliver({ op: 'get_meta', name: 'b.bin', size: 4, id: secondId })
    ch.deliver({ op: 'get_eof', id: firstId })      // the OLD fetch's eof
    await assert.rejects(new Promise((resolve, reject) => {
      void second.then(resolve, (e) => reject(e))
      setTimeout(() => reject(new Error('stale eof completed the fetch')), 50)
    }), /stale eof completed/)
    ch.deliver({ op: 'get_eof', id: secondId })
    assert.deepEqual(await second, new Blob([]))
  } finally { realTime() }
})

test('negotiate() applies only to the channel it was requested for', async () => {
  virtualTime()
  try {
    const transfer = new FileTransfer()
    const ch1 = stubChannel()
    transfer.attach(ch1)
    transfer.negotiate(ch1, { features: ['files.transfer_ids'] })
    assert.equal(transfer.peerEchoesTransferIds, true)
    const ch2 = stubChannel()
    transfer.attach(ch2)
    // The replacement starts fresh (legacy default) and a stale response for
    // the replaced channel must not flip it.
    assert.equal(transfer.peerEchoesTransferIds, false)
    transfer.negotiate(ch1, { features: ['files.transfer_ids'] })
    assert.equal(transfer.peerEchoesTransferIds, false)
    transfer.negotiate(ch2, { features: ['files.transfer_ids'] })
    assert.equal(transfer.peerEchoesTransferIds, true)
    transfer.negotiate(ch2, null)   // failed refresh: HTTP-selected uploads
    assert.equal(transfer.peerEchoesTransferIds, false)
  } finally { realTime() }
})
