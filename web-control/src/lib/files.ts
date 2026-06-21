// P2P file transfer over the WebRTC "files" DataChannel. It bypasses the relay
// (so any size, no body cap) and is paced against SCTP bufferbloat: dumping a
// whole file into the send buffer collapses usrsctp's congestion window, so we
// cap in-flight bytes at 512KB. Wire protocol (mirrors the device/daemon side):
//   download: send {op:get,path} -> recv {op:get_meta,name,size}, binary chunks,
//             {op:get_eof}
//   upload:   send {op:put,path,size}, 64KB binary chunks, {op:put_eof}
//             -> recv {op:put_ok}
//   errors:   {op:err,msg}
// Faithful port of the vanilla setupFilesChannel/fileCtrl/fDownloadDC/fUploadDC.

export type TransferStatus = { text: string; kind: 'idle' | 'down' | 'up' | 'err' }

export function fmtSize(n: number): string {
  return n < 1024 ? n + ' B' : n < 1048576 ? (n / 1024).toFixed(0) + ' KB' : (n / 1048576).toFixed(1) + ' MB'
}

function saveBlob(parts: ArrayBuffer[], name: string) {
  const blob = new Blob(parts)
  const u = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = u
  a.download = name
  a.click()
  setTimeout(() => URL.revokeObjectURL(u), 1500)
}

const CHUNK = 64 * 1024
const BACKPRESSURE = 512 << 10 // keep <=512KB in flight (SCTP bufferbloat guard)

export class FileTransfer {
  private ch: RTCDataChannel | null = null
  private dl: { name: string; size: number; got: number; parts: ArrayBuffer[] } | null = null
  private ul: { name: string; size: number } | null = null
  onStatus: (s: TransferStatus) => void = () => {}
  onDone: () => void = () => {} // refresh the listing after an upload completes

  attach(ch: RTCDataChannel) {
    this.ch = ch
    ch.binaryType = 'arraybuffer'
    ch.onmessage = (ev) => this.onMessage(ev)
    ch.onclose = () => {
      if (this.ch === ch) this.ch = null
      this.dl = null
      this.ul = null
      this.status('', 'idle')
    }
  }

  ready() {
    return !!this.ch && this.ch.readyState === 'open'
  }

  private status(text: string, kind: TransferStatus['kind']) {
    this.onStatus({ text, kind })
  }

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

  private ctrl(m: { op?: string; name?: string; size?: number; msg?: string }) {
    if (m.op === 'get_meta') {
      this.dl = { name: m.name || 'file', size: m.size || 0, got: 0, parts: [] }
      this.status(`↓ ${this.dl.name} 0%`, 'down')
    } else if (m.op === 'get_eof') {
      if (this.dl) {
        saveBlob(this.dl.parts, this.dl.name)
        this.dl = null
        this.status('', 'idle')
      }
    } else if (m.op === 'put_ok') {
      this.ul = null
      this.status('', 'idle')
      this.onDone()
    } else if (m.op === 'err') {
      this.dl = null
      this.ul = null
      this.status(`⚠ ${m.msg || 'error'}`, 'err')
    }
  }

  download(path: string, name: string): boolean {
    if (!this.ready() || this.dl) return false
    this.dl = { name: name || 'file', size: 0, got: 0, parts: [] } // provisional until get_meta
    this.ch!.send(JSON.stringify({ op: 'get', path }))
    return true
  }

  async upload(file: File, destPath: string): Promise<boolean> {
    if (!this.ready() || this.ul) return false
    this.ul = { name: file.name, size: file.size }
    this.ch!.send(JSON.stringify({ op: 'put', path: destPath, size: file.size }))
    let off = 0
    while (off < file.size) {
      while (this.ch!.bufferedAmount > BACKPRESSURE) await new Promise((r) => setTimeout(r, 2))
      const buf = await file.slice(off, off + CHUNK).arrayBuffer()
      this.ch!.send(buf)
      off += buf.byteLength
      this.status(`↑ ${file.name} ${Math.floor((off / file.size) * 100)}%`, 'up')
    }
    this.ch!.send(JSON.stringify({ op: 'put_eof' }))
    return true
  }
}
