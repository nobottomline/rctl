// P2P file transfer over the WebRTC "files" DataChannel. In-memory fetches are
// reserved for bounded previews and browser-side processing; normal downloads
// use the streaming HTTP tunnel in rctl.ts. Wire protocol (device/daemon mirror):
//   fetch:    send {op:get,path,id} -> recv {op:get_meta,name,size}, binary chunks,
//             {op:get_eof}; errors echo the id
//   upload:   send {op:put,path,size,id}, 64KB binary chunks, {op:put_eof,id}
//             -> recv {op:put_ok,bytes,id} (id echoed by files.transfer_ids daemons)
//   errors:   {op:err,msg[,id]}
// Faithful port of the vanilla setupFilesChannel/fileCtrl/fDownloadDC/fUploadDC.

export type TransferStatus = { text: string; kind: 'idle' | 'down' | 'up' | 'err' }

export function fmtSize(n: number): string {
  return n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB'
}

// Trigger a browser download of a Blob. Caller should invoke this synchronously
// within (or in the gesture's async continuation of) a user click -- Safari only
// permits programmatic downloads while the user activation is live, which is why
// downloads must be driven from the click handler, not the channel's onmessage.
// The anchor is also appended to the document: Safari/Firefox ignore click() on a
// detached element (Chrome allows it).
export function saveBlobToFile(blob: Blob, name: string) {
  const u = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = u
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(u), 1500)
}

const CHUNK = 64 * 1024
const BACKPRESSURE = 512 << 10 // keep <=512KB in flight (SCTP bufferbloat guard)

// Upload attempts are identified on the wire: the daemon echoes the id in
// put_ok/err, so a late answer after a timeout can never confirm a DIFFERENT
// attempt on the same channel. Downloads carry a 'd'-prefixed id for the same
// reason: an upload error reply can then never reject an unrelated download.
// A relay serves its web bundle independently of the device package, so an
// older daemon answers with bare (id-less) replies: capabilities negotiation
// (files.transfer_ids) decides whether id-less confirmations are accepted.
let uploadSeq = 0
let downloadSeq = 0
// The relayed HTTP fallback's body cap (bytes); 0 = device-local (no cap) or
// an old relay that did not publish it (then the blind fallback stays, as
// before this feature).
function relayBodyCap(): number | undefined {
  const w = globalThis as unknown as Record<string, unknown>
  const raw = w.RCTL_RELAY_TUNNEL_MAX_BODY
  if (raw === undefined || raw === '') return undefined   // not published
  const n = Number(raw)
  return Number.isFinite(n) && n >= 0 ? n : undefined
}

function idMatchesUpload(id: string): boolean {
  return id.length > 1 && id[0] === 'u' && id.slice(1) === String(Number(id.slice(1)))
}

function idMatchesDownload(id: string): boolean {
  return id.length > 1 && id[0] === 'd' && id.slice(1) === String(Number(id.slice(1)))
}

// One P2P upload attempt. The device answers with the id; the client
// matches replies by id (strict) or by the active slot (legacy).
export type UploadAttempt = {
  id: string
  size: number
  failed: boolean
  refused: boolean
  done: boolean
  ok: boolean
  started: boolean
  cancelSent: boolean
  eofSent: boolean
  // The status epoch this attempt was created in: statuses emitted by an
  // attempt are dropped once a NEWER upload() call (even a barriered one)
  // has started — the latest user intent owns the banner.
  epoch: number
}

// The outcome of a single upload() call. Returned TO THE CALLER so the panel
// decides from its own pick, never from the shared status stream.
// 'unsupported': the connection cannot carry this upload (an old daemon's
// id-less protocol makes P2P uploads unattributable, and an HTTP fallback
// through the relay is body-capped) — the caller must explain, not retry.
export type UploadOutcome = 'confirmed' | 'refused' | 'unconfirmed' | 'unsupported' | 'busy' | 'none'

export class FileTransfer {
  private ch: RTCDataChannel | null = null
  private dl: { name: string; size: number; got: number; parts: ArrayBuffer[] } | null = null
  private ul: { name: string; size: number; attempt: UploadAttempt } | null = null
  private putAttempts: UploadAttempt[] = []

  // The slot belongs to the attempt that claimed it: a finishing attempt
  // releases ONLY its own slot, never a newer attempt's.
  private releaseSlot(attempt: UploadAttempt) {
    if (this.ul?.attempt === attempt) this.ul = null
  }
  // True when the last upload was refused by the device (not merely when the
  // channel was busy/unavailable): the caller must not retry over HTTP.
  lastRefused = false
  // True when the last upload's acknowledgement never arrived: the daemon may
  // still be writing, so an HTTP re-push would truncate the file.
  lastUnconfirmed = false
  private dlResolve: ((b: Blob) => void) | null = null // set when fetch()ing to memory instead of downloading
  private dlReject: ((e: Error) => void) | null = null
  private dlId = ''   // the get id whose error replies may reject the pending fetch
  lastOutcome: 'none' | 'confirmed' | 'refused' | 'unconfirmed' | 'unsupported' | 'busy' = 'none'
  // The in-flight negotiation for the CURRENT channel, if any: an upload that
  // needs the transfer-id protocol can await it instead of guessing.
  private negotiation: Promise<void> | null = null
  // Protocol mode, bound to the CURRENT channel: renegotiated on every new
  // files channel (see negotiate), so a device package upgrade or rollback
  // is picked up by the next connection — never by a stale page-wide flag.
  peerEchoesTransferIds = false
  onStatus: (s: TransferStatus) => void = () => {}
  onDone: () => void = () => {} // refresh the listing after an upload completes

  attach(ch: RTCDataChannel) {
    this.ch = ch
    ch.binaryType = 'arraybuffer'
    // The new channel starts FRESH: the previous channel's protocol mode must
    // not leak into it (a reconnect after a daemon rollback must fall back to
    // the legacy flow, and an upgrade must not inherit strict), and its
    // pending fetch can no longer complete — reject it now and release the
    // slot so the replacement channel is usable immediately (its onclose may
    // not run at all after the replacement).
    this.peerEchoesTransferIds = false
    this.ul = null               // the replaced channel's slot is gone with it
    // RETIRE the old channel's attempts: their replies can never arrive
    // (onmessage is bound to the current channel), and a stale entry must
    // never be selected by an id-less matcher running on the new channel.
    // The old attempts' own local state still settles them (unconfirmed).
    // Outstanding eofs keep their entries across replacements: an id-less
    // ack for one of them can still be routed here by the OLD daemon, and
    // the count — not the channel — decides attributability.
    this.putAttempts = []
    if (this.dlReject) {
      this.dlReject(new Error('files channel replaced'))
      this.dlResolve = null
      this.dlReject = null
      this.dlId = ''
    }
    this.dl = null
    // Channel-bound close: a stale channel's close event must not end a
    // replacement attempt (each handler captures its own channel).
    ch.onmessage = (ev) => { if (this.ch === ch) this.onMessage(ev) }
    ch.onclose = () => {
      if (this.ch !== ch) return
      this.ch = null
      this.dl = null
      this.ul = null
      // A closed channel ends any waiting upload attempt WITHOUT marking a
      // device refusal — but the write MAY already be in flight at the
      // daemon, so a file without an explicit verdict is reported
      // unconfirmed; an attempt the device already refused keeps its own
      // outcome even when the close lands before upload() returns.
      for (const attempt of this.putAttempts) attempt.failed = true
      if (this.putAttempts.length) this.lastUnconfirmed = true
      // A pending fetch must never hang: the channel that would have
      // delivered its bytes is gone.
      if (this.dlReject) {
        this.dlReject(new Error('files channel closed'))
        this.dlResolve = null
        this.dlReject = null
        this.dlId = ''
      }
      this.status('', 'idle')
    }
  }

  ready() {
    return !!this.ch && this.ch.readyState === 'open'
  }

  // Apply a capabilities response to the channel generation it was requested
  // for: a stale or failed refresh must not overwrite the CURRENT channel's
  // mode. A null/failed capability load falls back to legacy-tolerant, which
  // is safe against a new daemon (it never emits id-less confirmations) and
  // functional against an old one.
  negotiate(ch: RTCDataChannel, capabilities: { features: string[] } | null) {
    if (this.ch !== ch) return
    this.peerEchoesTransferIds = !!capabilities?.features.includes('files.transfer_ids')
  }

  // Record the negotiation promise for the current channel so an upload can
  // wait for the capability decision instead of racing it. Each negotiation
  // carries its own shared signal that resolves when the decision lands; a
  // REPLACEMENT resolves the old signal too (every waiter parked on the old
  // promise wakes and follows the newer negotiation), but a STALE
  // negotiation's own completion can never wake a waiter parked on the
  // CURRENT one — the signal is replaced with the promise.
  private negotiationWaiter: Promise<void> = Promise.resolve()
  private negotiateWaiter: ((v: void) => void) | null = null

  beginNegotiation(ch: RTCDataChannel, pending: Promise<{ features: string[] } | null>) {
    if (this.ch !== ch) return
    // Wake every waiter parked on the OLD promise: the replacement's
    // decision is now the one that matters.
    this.negotiateWaiter?.(undefined)
    this.negotiateWaiter = null
    let resolveCurrent: (v: void) => void = () => {}
    this.negotiationWaiter = new Promise<void>((resolve) => { resolveCurrent = resolve })
    this.negotiateWaiter = resolveCurrent
    this.negotiation = pending
      .then((capabilities) => { this.negotiate(ch, capabilities); resolveCurrent() })
      .catch(() => { this.negotiate(ch, null); resolveCurrent() })
  }

  // The CURRENT negotiation's completion-or-replacement signal: waiters
  // parked on older negotiations follow through this.
  private negotiationSignal(): Promise<void> {
    return this.negotiationWaiter
  }

  private status(text: string, kind: TransferStatus['kind'], fromEpoch?: number) {
    // An attempt-scoped status is dropped once a newer upload() call started:
    // the latest user intent owns the banner, across both status writers.
    if (fromEpoch !== undefined && fromEpoch < this.epoch) return
    this.onStatus({ text, kind })
  }
  private epoch = 0

  private onMessage(ev: MessageEvent) {
    if (typeof ev.data === 'string') {
      try {
        this.ctrl(JSON.parse(ev.data))
      } catch {
        /* ignore */
      }
      return
    }
    if (this.dl) {
      const buf = ev.data as ArrayBuffer
      this.dl.parts.push(buf)
      this.dl.got += buf.byteLength
      const pct = this.dl.size ? Math.floor((this.dl.got / this.dl.size) * 100) + '%' : fmtSize(this.dl.got)
      this.status(`↓ ${this.dl.name} ${pct}`, 'down')
    }
  }

  private ctrl(m: { op?: string; name?: string; size?: number; msg?: string; id?: string }) {
    if (m.op === 'get_meta') {
      // An id-carrying meta belongs to exactly one fetch; a legacy daemon's
      // id-less meta applies to whatever fetch is pending.
      if (m.id && m.id !== this.dlId) return
      this.dl = { name: m.name || 'file', size: m.size || 0, got: 0, parts: [] }
      this.status(`↓ ${this.dl.name} 0%`, 'down')
    } else if (m.op === 'get_eof') {
      if (m.id && m.id !== this.dlId) return   // a stale eof from an old fetch
      if (this.dl) {
        const { parts } = this.dl
        const cancelled = (m as { cancelled?: boolean }).cancelled === true
        this.dl = null
        this.status('', 'idle')
        if (cancelled) {
          // A cancelled transfer is a failed download: the caller must not
          // store or display a partial file as if it were complete.
          if (this.dlReject) {
            this.dlReject(new Error('download cancelled'))
            this.dlResolve = null
            this.dlReject = null
            this.dlId = ''
          }
          return
        }
        if (this.dlResolve) {
          this.dlResolve(new Blob(parts))
          this.dlResolve = null
          this.dlReject = null
          this.dlId = ''
        }
      }
    } else if (m.op === 'put_ok') {
      // Strict mode: only THIS attempt's own confirmation lands (the
      // unguessable id binds it, and an old daemon's id-less ack can never
      // match — legacy uploads never start at all).
      const attempt = this.putAttempts.find(
        (a) => a.id === (m as { id?: string }).id && a.eofSent && !a.done && !a.failed)
      if (!attempt) return   // an unmatched reply must change nothing
      const bytes = (m as { bytes?: number }).bytes
      if (typeof bytes !== 'number' || bytes !== attempt.size) {
        // A byte-count mismatch (e.g. an old daemon answering a failed write
        // with put_ok 0) is a FAILED upload, never a phantom success. The
        // verdict binds by HOW the ack matched: an id-carrying ack is
        // definitive for this attempt (regardless of when the capabilities
        // response landed), while an id-less legacy ack is unattributable in
        // principle — the conservative unconfirmed verdict with the barrier.
        attempt.failed = true
        attempt.refused = true
        this.releaseSlot(attempt)
        this.lastRefused = true
        this.lastUnconfirmed = false
        this.status('⚠ upload write failed', 'err', attempt.epoch)
        return
      }
      attempt.ok = true
      attempt.done = true    // terminal: cannot be re-applied
      this.releaseSlot(attempt)
      this.status('', 'idle', attempt.epoch)
      this.onDone()
    } else if (m.op === 'err') {
      const eid = (m as { id?: string }).id
      if (eid && idMatchesUpload(eid)) {
        // Upload-domain errors belong to exactly one attempt and never touch
        // a pending fetch: a late answer from a retired attempt is ignored
        // entirely, before any state changes.
        const attempt = this.putAttempts.find((a) => a.id === eid && !a.done && !a.failed)
        if (!attempt) return
        attempt.failed = true
        attempt.refused = true
        this.releaseSlot(attempt)
        this.status(`⚠ ${m.msg || 'error'}`, 'err', attempt.epoch)
        return
      }
      if (eid && idMatchesDownload(eid)) {
        // A download error belongs to exactly one fetch — only its own id
        // may reject it.
        if (this.dlReject && eid === this.dlId) {
          this.dl = null
          this.dlReject(new Error(m.msg || 'error'))
          this.dlResolve = null
          this.dlReject = null
          this.dlId = ''
          this.status(`⚠ ${m.msg || 'error'}`, 'err')
        }
        return
      }
      // An id-less err is a LEGACY daemon answer (the current daemon echoes
      // ids on every upload/get error). Which transfer it belongs to is
      // unknowable, so in legacy mode BOTH pending directions take the
      // CONSERVATIVE path: the active upload is marked failed-unconfirmed
      // (never refused — the caller must not auto-retry over HTTP, and a
      // later legacy put_ok can no longer confirm it, so an old daemon's
      // failed empty-file write is never a phantom success), and the pending
      // fetch is rejected. A strict daemon never sends id-less upload/get
      // errors... except get errors, which carry no id by design — so in
      // strict mode an id-less err stays DOWNLOAD-only and can never clobber
      // an upload.
      this.dl = null
      if (this.dlReject) {
        this.dlReject(new Error(m.msg || 'error'))
        this.dlResolve = null
        this.dlReject = null
        this.dlId = ''
      }
      this.status(`⚠ ${m.msg || 'error'}`, 'err')
    } else if (m.op === 'put_started') {
      // Strict protocol: the daemon accepted the put (reservation + stream
      // attached). Only now may chunks flow.
      const attempt = this.putAttempts.find((a) => a.id === (m as { id?: string }).id && !a.done && !a.failed)
      if (attempt) attempt.started = true
    }
  }

  // Release the daemon-side reservation of a failed attempt: the cancel
  // must actually be enqueued, so a throwing send on an open channel waits
  // for the send queue to drain and retries, bounded. Giving up leaves the
  // device-side reap (channel close) as the last resort.
  private async releaseReservation(ch: RTCDataChannel, attempt: { id: string; cancelSent: boolean; eofSent?: boolean }) {
    for (let tries = 0; tries < 5 && !attempt.cancelSent; tries++) {
      if (ch.readyState !== 'open') return
      try {
        ch.send(JSON.stringify({ op: 'cancel', id: attempt.id }))
        attempt.cancelSent = true
      } catch {
        const drainDeadline = Date.now() + 1000
        while (ch.readyState === 'open' && ch.bufferedAmount > 0 && Date.now() < drainDeadline) {
          await new Promise((r) => setTimeout(r, 10))
        }
      }
    }
  }

  // Transport-agnostic upload slot: the HTTP fallback claims the SAME
  // serialization the P2P path uses, so two picks can never write one target
  // in an order neither the browser nor the daemon controls.
  private httpUploadActive = false

  claimUploadSlot(): boolean {
    if (this.httpUploadActive || this.ul) return false
    this.httpUploadActive = true
    return true
  }

  releaseUploadSlot() {
    this.httpUploadActive = false
  }

  // Fetch a file into memory over the P2P channel (preview, not download). Used for
  // camera/screenshot images the relay WebSocket can't carry. Rejects if the channel
  // is busy/closed or the device errors; resolves with the Blob on completion.
  fetch(path: string): Promise<Blob> {
    return new Promise((resolve, reject) => {
      if (!this.ready() || this.dl) {
        reject(new Error('files channel busy'))
        return
      }
      this.dl = { name: '', size: 0, got: 0, parts: [] }
      this.dlResolve = resolve
      this.dlReject = reject
      this.dlId = 'd' + ++downloadSeq
      try {
        this.ch!.send(JSON.stringify({ op: 'get', path, id: this.dlId }))
      } catch (e) {
        // Reject AND release: a dead send must not wedge the fetch slot.
        this.dl = null
        this.dlResolve = null
        this.dlReject = null
        this.dlId = ''
        reject(e instanceof Error ? e : new Error('send failed'))
      }
    })
  }

  async upload(file: File, destPath: string): Promise<UploadOutcome> {
    const myEpoch = ++this.epoch   // every pick owns the banner from here on
    // Busy FIRST: a channel stuck in closing (onclose not yet delivered)
    // still has an active upload whose target an HTTP fallback would
    // truncate, even though ready() is already false.
    if (this.ul || this.httpUploadActive) {
      // An upload is already in flight (P2P or HTTP): an automatic fallback
      // could truncate or reorder the very target being written. Refuse the
      // fallback for this pick; the caller retries explicitly.
      this.lastOutcome = 'busy'
      this.lastUnconfirmed = true
      this.status('⚠ upload busy', 'err')
      return 'busy'
    }
    // The barrier comes BEFORE the channel check: a channel stuck in closing
    // with an unknown previous fate must not take the HTTP-eligible path.
    // P2P uploads REQUIRE the transfer-id protocol: an old daemon answers
    // with id-less acks it routes through its global newest channel, where
    // they are unattributable in principle (no reap guarantee, other
    // sessions' eofs, replaced attempts). If the capability decision is
    // still in flight, wait for it (bounded) before deciding; an
    // un-negotiated channel selects the HTTP upload BEFORE any P2P put is
    // sent — or, when the relayed HTTP fallback cannot carry the file
    // (tunnel body cap), reports 'unsupported' for the caller to explain
    // instead of a blind 413.
    // The decision is bound to the CURRENT channel: a replacement's
    // beginNegotiation installs its own promise, and this loop follows the
    // channel across replacements (bounded once by the overall deadline) —
    // a stale waiter can never decide the transport for a newer channel.
    // The decision wait follows the CURRENT channel across replacements
    // (the notifier fires when the negotiation settles or a replacement
    // re-arms), bounded by THIS pick's 10s wait budget. Expiry ends only
    // this pick's WAIT — the pending decision itself is never discarded, so
    // a later pick re-arms on it instead of instant-failing.
    const overallDeadline = Date.now() + 10000
    for (;;) {
      const negotiation = this.negotiation
      if (!negotiation || Date.now() >= overallDeadline) break
      // Wait on the SHARED signal of the negotiation we parked on: it
      // resolves when THAT negotiation lands or a replacement re-arms — a
      // stale negotiation's own completion can never fire the CURRENT
      // waiter's wake, because the signal object is replaced with the
      // promise. The bound stays local to THIS pick.
      const signal = this.negotiationSignal()
      const settled = await Promise.race([
        signal.then(() => 'decided' as const),
        new Promise<'bound'>((r) => {
          setTimeout(() => r('bound'), Math.max(0, overallDeadline - Date.now()))
        }),
      ] as Promise<'decided' | 'bound'>[])
      // A replacement re-armed while we waited: follow its newer promise
      // (the pending decision stays for whoever follows it).
      if (this.negotiation !== negotiation) continue
      // The decision we parked on is still the current one. On expiry we
      // leave it PENDING — our budget ends only OUR wait; a later pick
      // re-arms on it instead of instant-failing.
      if (settled === 'bound') break
      this.negotiation = null   // decided: consume ours
      break                     // the decision is ours: done
    }
    // ONE post-decision gate covers every HTTP-eligible exit (un-negotiated
    // or lost channel): the relay body cap applies to the fallback wherever
    // it would be selected, so an oversized file can never blind-push a 413.
    // A PUBLISHED cap of 0 rejects every nonempty body at the relay — it is
    // a real limit, not the absence of one.
    const httpEligible = !this.peerEchoesTransferIds || !this.ready()
    if (httpEligible) {
      this.lastRefused = false
      this.lastUnconfirmed = false
      const published = relayBodyCap()
      const cap = published === undefined ? 0 : published
      if (published !== undefined && file.size > cap) {
        this.lastOutcome = 'unsupported'
        this.status('⚠ this connection caps uploads — use LAN or update the device', 'err', myEpoch)
        return 'unsupported'
      }
      this.lastOutcome = 'none'
      return 'none'
    }
    // Strict P2P path: after the awaits, synchronously re-check the HTTP
    // slot before claiming the P2P slot — an HTTP fallback that started
    // during the negotiation await must never race this put. (The P2P
    // attempt serializes through this.ul; it must not hold the HTTP slot,
    // or a dead attempt's stale claim would block fresh uploads.)
    if (this.httpUploadActive || this.ul) {
      this.lastOutcome = 'busy'
      this.lastUnconfirmed = true
      this.status('⚠ upload busy', 'err', myEpoch)
      return 'busy'
    }
    // Per-attempt state, bound to the channel it started on: every read and
    // send below goes through the captured `ch`, so a close that nulls
    // this.ch mid-loop cannot throw, and a REPLACEMENT channel can never
    // receive this attempt's chunks or eof.
    const ch = this.ch!
    const attempt: UploadAttempt = { id: 'u' + ++uploadSeq, size: file.size, failed: false, refused: false, done: false, ok: false, started: false, cancelSent: false, eofSent: false, epoch: myEpoch }
    this.putAttempts.push(attempt)
    this.ul = { name: file.name, size: file.size, attempt }
    this.lastRefused = false
    this.lastUnconfirmed = false
    let off = 0
    let sendFailure = false
    try {
      ch.send(JSON.stringify({ op: 'put', path: destPath, size: file.size, id: attempt.id }))
    } catch {
      sendFailure = true
    }
    const putSent = !sendFailure
    const finish = (outcome: UploadOutcome): UploadOutcome => {
      this.lastOutcome = outcome
      return outcome
    }
    this.lastOutcome = 'none'
    if (!sendFailure && this.peerEchoesTransferIds) {
      // Strict protocol: wait until the daemon ACCEPTS the put
      // (put_started) before any byte flows — a refused or timed-out put
      // must never write chunks into a stream it does not own. The wait
      // watches the channel state and is bounded.
      const startDeadline = Date.now() + 15000
      while (!attempt.started && !attempt.done && !attempt.refused && !attempt.failed &&
             ch.readyState === 'open' && Date.now() < startDeadline) {
        await new Promise((r) => setTimeout(r, 20))
      }
      if (!attempt.started && !attempt.done) {
        // Refused, timed out, or the channel died before acceptance. Release
        // this attempt's reservation with an id-carrying cancel: the daemon
        // processes ordered messages in order (put first, cancel second), so
        // one cancel always sees the reservation the put took — and naming
        // the id means a late retry can never close a NEWER attempt's stream.
        attempt.failed = true
        if (!attempt.refused) {
          this.lastUnconfirmed = true   // an explicit refusal keeps its own verdict
        }
        this.putAttempts = this.putAttempts.filter((a) => a !== attempt)
        this.releaseSlot(attempt)
        await this.releaseReservation(ch, attempt)
        if (attempt.refused) {
          this.lastRefused = true
          this.lastUnconfirmed = false
          this.status('⚠ upload refused', 'err', attempt.epoch)
          return finish('refused')
        }
        this.status('⚠ upload unconfirmed', 'err', attempt.epoch)
        return finish('unconfirmed')
      }
    }
    while (off < file.size && !attempt.failed && !sendFailure) {
      if (attempt.refused) break
      // The backpressure wait also watches the channel state: a channel
      // stuck in closing with a full buffer cannot hang the upload past
      // onclose delivery.
      while (ch.bufferedAmount > BACKPRESSURE && !attempt.failed &&
             ch.readyState === 'open') {
        await new Promise((r) => setTimeout(r, 2))
      }
      if (ch.readyState !== 'open' || attempt.failed) {
        // The write may already be at the daemon: unconfirmed, not failed —
        // unless the device already gave an explicit verdict (refused or
        // confirmed), which keeps its own outcome.
        attempt.failed = true
        if (!attempt.refused && !attempt.done) this.lastUnconfirmed = true
        break
      }
      let buf: ArrayBuffer
      try {
        buf = await file.slice(off, off + CHUNK).arrayBuffer()
      } catch {
        attempt.failed = true
        if (!attempt.refused && !attempt.done) this.lastUnconfirmed = true
        break
      }
      // The channel can have entered closing while the read was pending;
      // sending then throws (or worse, silently queues on a dead channel).
      // An EXPLICIT device refusal (already recorded) keeps its own outcome:
      // only a genuinely ambiguous stop is reported unconfirmed.
      if (ch.readyState !== 'open' || attempt.failed) {
        attempt.failed = true
        if (!attempt.refused && !attempt.done) this.lastUnconfirmed = true
        break
      }
      try {
        ch.send(buf)
      } catch {
        attempt.failed = true
        if (!attempt.refused && !attempt.done) this.lastUnconfirmed = true
        break
      }
      off += buf.byteLength
      this.status(`↑ ${file.name} ${Math.floor((off / file.size) * 100)}%`, 'up', attempt.epoch)
    }
    if (!attempt.failed && !sendFailure) {
      try {
        ch.send(JSON.stringify({ op: 'put_eof', id: attempt.id }))
        attempt.eofSent = true
      } catch {
        sendFailure = true
      }
    }
    if (sendFailure && !attempt.failed) {
      // Nothing after the last acknowledged state guarantees delivery: treat
      // a failed send like an unconfirmed write.
      attempt.failed = true
      this.lastUnconfirmed = true
    }
    if (attempt.failed && !attempt.cancelSent && putSent && ch.readyState === 'open') {
      // The daemon may hold this attempt's reservation and open stream even
      // without an acceptance: a legacy-mode read failure (or a strict
      // handshake that never resolved) leaves the put on the wire. Release
      // it with the id-carrying cancel so the next upload is not locked out
      // and /v1/push is not refused — and so this cancel can never close a
      // newer attempt that already replaced this one.
      await this.releaseReservation(ch, attempt)
    }
    // ... daemon answers put_ok/err echoing this attempt's id. The attempt
    // object itself carries the terminal outcome, so a late second answer
    // cannot terminate a later attempt. The wait is bounded AND watches the
    // channel: a channel stuck in closing (readyState no longer 'open',
    // onclose not yet delivered) cannot hang the upload — it reports
    // unconfirmed failure.
    const ackDeadline = Date.now() + 15000
    while (!attempt.done && !attempt.failed &&
           ch.readyState === 'open' && Date.now() < ackDeadline) {
      await new Promise((r) => setTimeout(r, 20))
    }
    this.putAttempts = this.putAttempts.filter((a) => a !== attempt)
    if (attempt.refused) {
      this.lastRefused = true
      this.lastUnconfirmed = false   // exactly one outcome: the explicit verdict wins
      this.status('⚠ upload refused', 'err', attempt.epoch)
      return finish('refused')
    }
    if (!attempt.ok) {
      // No acknowledgement arrived (channel closing, ack timed out): the
      // daemon may still be writing this file's chunks, so an HTTP re-push
      // would truncate it — refuse THIS file's fallback and make the caller
      // retry explicitly. In legacy mode the next upload is BARRIERED until
      // a fresh channel: id-less replies can no longer be attributed after
      // this ambiguous end (the barrier binds to the attempt's OWN channel —
      // a replacement that already happened must not be blocked by it).
      this.lastUnconfirmed = true
      this.releaseSlot(attempt)
      this.status('⚠ upload unconfirmed', 'err', attempt.epoch)
      return finish('unconfirmed')
    }
    return finish('confirmed')
  }
}
