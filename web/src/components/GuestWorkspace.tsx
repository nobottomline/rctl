import { useEffect, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import { guestHas } from '../lib/rctl'
import { GuestOperations, guestDecode, guestEncode, type GuestTransfer } from '../lib/guestOperations'
import { AudioPlayer } from '../lib/audio'
import { MicTalk } from '../lib/mic'
import type { ControlEngine, MacroEvent } from '../lib/engine'
import { CameraTransport } from '../lib/camera'

function GuestPointer({ operations, onError }: { operations: GuestOperations; onError: (message: string) => void }) {
  const [active,setActive]=useState(false)
  const sequence=useRef(0), pending=useRef({dx:0,dy:0,wheel:0}), position=useRef<{x:number;y:number}|null>(null)
  const inFlight=useRef(false)
  useEffect(() => {
    if(!active)return
    let alive=true
    const release=() => {setActive(false);position.current=null;void operations.call('input.pointer',{action:'release'}).catch(()=>{})}
    const timer=window.setInterval(() => {
      if(inFlight.current)return
      const delta=pending.current;pending.current={dx:0,dy:0,wheel:0};inFlight.current=true
      void operations.call('input.pointer',{action:'state',sequence:++sequence.current,buttons:0,...delta})
        .catch(error=>{if(alive){onError(String(error));release()}}).finally(()=>{inFlight.current=false})
    },100)
    const hidden=()=>{if(document.hidden)release()};document.addEventListener('visibilitychange',hidden);window.addEventListener('blur',release)
    return ()=>{alive=false;clearInterval(timer);document.removeEventListener('visibilitychange',hidden);window.removeEventListener('blur',release);void operations.call('input.pointer',{action:'release'}).catch(()=>{})}
  },[active,operations,onError])
  const click=async(buttons:number)=>{try{await operations.call('input.pointer',{action:'state',sequence:++sequence.current,buttons,dx:0,dy:0,wheel:0});await operations.call('input.pointer',{action:'state',sequence:++sequence.current,buttons:0,dx:0,dy:0,wheel:0})}catch(error){onError(String(error));setActive(false)}}
  return <details><summary>Relative mouse</summary><button onClick={()=>{if(active)setActive(false);else void operations.call<{sequence:number}>('input.pointer',{action:'acquire'}).then(result=>{sequence.current=result.sequence;setActive(true)}).catch(error=>onError(String(error)))}}>{active?'Release pointer':'Acquire pointer'}</button>
    {active&&<><div className="guest-pointer-pad" role="application" aria-label="Drag to move the device pointer" onPointerDown={event=>{event.currentTarget.setPointerCapture(event.pointerId);position.current={x:event.clientX,y:event.clientY}}} onPointerMove={event=>{if(!position.current)return;pending.current.dx=Math.max(-2048,Math.min(2048,pending.current.dx+event.clientX-position.current.x));pending.current.dy=Math.max(-2048,Math.min(2048,pending.current.dy+event.clientY-position.current.y));position.current={x:event.clientX,y:event.clientY}}} onPointerUp={()=>{position.current=null}} onPointerCancel={()=>{position.current=null}}>Drag to move</div>
      <button onClick={()=>void click(1)}>Left click</button><button onClick={()=>void click(2)}>Right click</button><button onClick={()=>{pending.current.wheel=40}}>Scroll up</button><button onClick={()=>{pending.current.wheel=-40}}>Scroll down</button></>}
  </details>
}

function GuestTerminal({ operations, onError }: { operations: GuestOperations; onError: (message: string) => void }) {
  const container = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let alive = true
    let timer = 0
    const terminal = new Terminal({ fontSize: 13, scrollback: 1000, theme: { background: '#080b10', foreground: '#e7eaf0' } })
    const fit = new FitAddon(); terminal.loadAddon(fit); terminal.open(container.current!); fit.fit()
    const decoder = new TextDecoder()
    const size = () => ({ cols: Math.max(20, Math.min(500, terminal.cols)), rows: Math.max(5, Math.min(200, terminal.rows)) })
    const read = async () => {
      try {
        const value = await operations.call<{ data: string; eof: boolean }>('terminal.read')
        if (!alive) return
        if (value.eof) { onError('Terminal closed'); return }
        if (value.data) terminal.write(decoder.decode(guestDecode(value.data), { stream: true }))
        timer = window.setTimeout(() => void read(), value.data ? 0 : 100)
      } catch (error) { if (alive) onError(String(error)) }
    }
    void operations.call('terminal.open', size()).then(() => { if (alive) { terminal.focus(); void read() } }).catch((error) => { if (alive) onError(String(error)) })
    const input = terminal.onData((value) => {
      if (!alive) return
      const bytes = new TextEncoder().encode(value)
      if (bytes.length > 24576) { onError('Input is too large'); return }
      void operations.call<{ written: number }>('terminal.write', { data: guestEncode(bytes) }).then((result) => {
        if (result.written !== bytes.length && alive) onError('Terminal input was not fully accepted')
      }).catch((error) => { if (alive) onError(String(error)) })
    })
    const observer = new ResizeObserver(() => {
      if (!alive) return
      fit.fit(); void operations.call('terminal.resize', size()).catch(() => {})
    }); observer.observe(container.current!)
    return () => { alive = false; clearTimeout(timer); observer.disconnect(); input.dispose(); terminal.clear(); terminal.dispose(); void operations.call('terminal.close').catch(() => {}) }
  }, [operations, onError])
  return <div ref={container} className="guest-terminal" aria-label="Root terminal" />
}

function GuestCamera({ operations }: { operations: GuestOperations }) {
  const video = useRef<HTMLVideoElement>(null)
  const transport = useRef<CameraTransport | null>(null)
  const [status, setStatus] = useState('Camera off')
  const [live, setLive] = useState(false)
  const [position, setPosition] = useState('back')
  useEffect(() => {
    const camera = new CameraTransport(video.current!, { onState: setStatus }); transport.current = camera
    return () => { camera.stop(); transport.current = null; void operations.call('camera.live', { on: false }).catch(() => {}) }
  }, [operations])
  const toggle = async () => {
    try {
      await operations.call('camera.live', { on: !live, position })
      if (live) transport.current?.stop(); else { transport.current?.start(); transport.current?.setExpectedLive(true) }
      setLive(!live)
    } catch (error) { setStatus(String(error)) }
  }
  return <section><h3>Camera</h3><label>Position <select value={position} disabled={live} onChange={(event) => setPosition(event.target.value)}><option value="back">Back</option><option value="front">Front</option></select></label>
    <button onClick={() => void toggle()}>{live ? 'Stop camera' : 'Start camera'}</button><p role="status">{status}</p><video ref={video} muted playsInline className="guest-camera" /></section>
}

type FileItem = { name: string; directory: boolean; size: number }
type MediaItem = { id: string; name: string; type: string; deletable?: boolean }
function GuestResult({value}:{value:string}) {
  let parsed:unknown=value;try{parsed=JSON.parse(value)}catch{/* A bounded text-file preview. */}
  const render=(item:unknown,depth=0):React.ReactNode=>{
    if(depth>5)return <span>More details unavailable</span>
    if(Array.isArray(item))return <div className="guest-result-list">{item.map((child,index)=><div key={index}>{render(child,depth+1)}</div>)}</div>
    if(item!==null&&typeof item==='object')return <dl>{Object.entries(item).map(([key,child])=><div key={key}><dt>{key.replaceAll('_',' ').replace(/^./,letter=>letter.toUpperCase())}</dt><dd>{render(child,depth+1)}</dd></div>)}</dl>
    return <span>{item===null?'—':typeof item==='boolean'?(item?'Yes':'No'):String(item)}</span>
  }
  return <div className="guest-result">{render(parsed)}</div>
}
export default function GuestWorkspace({ operations, ready, audio, microphone, talk, engine }: {
  engine: React.RefObject<ControlEngine | null>; operations: GuestOperations; ready: boolean; audio: AudioPlayer; microphone: AudioPlayer; talk: MicTalk
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [output, setOutput] = useState('')
  const [text, setText] = useState('')
  const [bundle, setBundle] = useState('')
  const [url, setURL] = useState('https://')
  const [path, setPath] = useState('')
  const [files, setFiles] = useState<FileItem[]>([])
  const [media, setMedia] = useState<MediaItem[]>([])
  const [cursor, setCursor] = useState<number | null>(0)
  const [inventory,setInventory]=useState<{kind:string;next:number|null}|null>(null)
  const [preview, setPreview] = useState('')
  const [previewVideo,setPreviewVideo]=useState(false)
  const [previewCapture,setPreviewCapture]=useState(false)
  const [previewName,setPreviewName]=useState('capture')
  const [terminal, setTerminal] = useState(false)
  const [recordingMic, setRecordingMic] = useState(false)
  const [recordingCamera, setRecordingCamera] = useState(false)
  const [snapshotPosition, setSnapshotPosition] = useState('back')
  const [macro, setMacro] = useState<MacroEvent[]>([])
  const [recordingMacro, setRecordingMacro] = useState(false)
  const [playingMacro, setPlayingMacro] = useState(false)
  const [listening, setListening] = useState(false)
  const [room, setRoom] = useState(false)
  const [talking, setTalking] = useState(false)
  const [progress, setProgress] = useState<number | null>(null)
  const [overwrite, setOverwrite] = useState(false)
  const abort = useRef(new AbortController())
  const urls = useRef(new Set<string>())
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true; abort.current = new AbortController()
    talk.onError = setError; talk.onState = setTalking
    return () => { mounted.current = false; abort.current.abort(); audio.mute(); microphone.mute(); talk.stop(); urls.current.forEach((url) => URL.revokeObjectURL(url)); urls.current.clear() }
  }, [audio, microphone, talk])
  useEffect(() => {
    if (!ready || (!recordingMic && !recordingCamera)) return
    let alive = true; let pending = false
    const timer = window.setInterval(async () => {
      if (pending) return
      pending = true
      try {
        const status = await operations.call<{ microphone?: boolean; camera?: boolean }>('capture.status')
        if (alive) { if (status.microphone !== undefined) setRecordingMic(status.microphone); if (status.camera !== undefined) setRecordingCamera(status.camera) }
      } catch (error) { if (alive) setError(String(error)) }
      finally { pending = false }
    }, 1000)
    return () => { alive = false; clearInterval(timer) }
  }, [operations, ready, recordingMic, recordingCamera])
  async function action(work: () => Promise<unknown>) {
    if (busy || !ready) return
    setBusy(true); setError('')
    try { await work() } catch (error) { if (mounted.current) setError(error instanceof Error ? error.message : String(error)) }
    finally { if (mounted.current) { setBusy(false); setProgress(null) } }
  }
  async function listen(player: AudioPlayer, op: string, active: boolean, update: (value: boolean) => void) {
    if (!active && !await player.resume()) throw new Error('Browser audio could not start')
    try { await operations.call(op, { on: !active }); if (active) player.mute(); update(!active) }
    catch (error) { if (!active) player.mute(); throw error }
  }
  async function inspect(op: string, args: Record<string, unknown> = {}) {
    const value = await operations.call(op, args)
    if (mounted.current) setOutput(JSON.stringify(value, null, 2))
  }
  async function file(op: string, args: Record<string, unknown>, display = false, video = false) {
    const picker = (window as unknown as { showSaveFilePicker?: (options: { suggestedName: string }) => Promise<{ createWritable: () => Promise<{ write: (data: Uint8Array<ArrayBuffer>) => Promise<void>; close: () => Promise<void>; abort: () => Promise<void> }> }> }).showSaveFilePicker
    // Invoke the picker in the original user gesture, before any network await.
    const handle = !display && picker ? await picker({ suggestedName: 'device-download' }) : null
    const transfer = await operations.call<GuestTransfer>(op, args)
    if (handle) { await operations.save(transfer, await handle.createWritable(), abort.current.signal, setProgress); return }
    const blob = await operations.read(transfer, display ? 64 * 1024 * 1024 : 256 * 1024 * 1024, abort.current.signal)
    if (!mounted.current) return
    const objectURL = URL.createObjectURL(blob); urls.current.add(objectURL)
    if (display) { if (preview) { URL.revokeObjectURL(preview); urls.current.delete(preview) } setPreviewVideo(video);setPreviewCapture(op==='screen.snapshot'||op==='camera.snapshot');setPreviewName(transfer.name);setPreview(objectURL) }
    else { const anchor = document.createElement('a'); anchor.href = objectURL; anchor.download = transfer.name; anchor.click(); window.setTimeout(() => { URL.revokeObjectURL(objectURL); urls.current.delete(objectURL) }, 10000) }
  }
  async function loadFiles(next = path) {
    const result = await operations.call<{ items: FileItem[] }>('files.list', { path: next })
    if (mounted.current) { setPath(next); setFiles(result.items) }
  }
  async function loadMedia(next: number) {
    const result = await operations.call<{ items: MediaItem[]; next: number | null }>('media.browse', { cursor: next })
    if (mounted.current) { setMedia(result.items); setCursor(result.next) }
  }
  async function loadInventory(kind:string,cursor=0) {
    const result=await operations.call<{items:unknown[];next:number|null;total:number}>('system.inventory',{kind,cursor})
    if(mounted.current){setInventory({kind,next:result.next});setOutput(JSON.stringify(result))}
  }
  const childPath = (name: string) => path ? `${path}/${name}` : name
  const command = (op: string, args: Record<string, unknown> = {}) => () => void action(() => inspect(op, args))
  return <div className="guest-workspace" aria-label="Permitted device tools">
    <p role="status">{ready ? 'Device tools connected' : 'Waiting for device tools…'}</p>
    <fieldset disabled={busy || !ready}>
      {(guestHas('device.info') || guestHas('device.diagnostics') || guestHas('device.brightness') || guestHas('device.orientation') || guestHas('screen.snapshot')) && <details><summary>Device</summary><div className="guest-actions">
        {guestHas('device.info') && <button onClick={command('device.info')}>Information</button>}
        {guestHas('device.diagnostics') && <button onClick={command('device.diagnostics')}>Diagnostics</button>}
        {guestHas('device.brightness') && <label>Brightness <input aria-label="Device brightness" type="range" min="0" max="1" step="0.05" defaultValue="0.5" onPointerUp={(event) => void action(() => inspect('device.brightness', { value: Number(event.currentTarget.value) }))} /></label>}
        {guestHas('device.orientation') && <label>Orientation <select defaultValue="0" onChange={(event) => void action(() => inspect('device.orientation', { orientation: Number(event.target.value) }))}>{['Automatic', 'Portrait', 'Portrait upside down', 'Landscape left', 'Landscape right'].map((name, index) => <option key={name} value={index}>{name}</option>)}</select></label>}
        {guestHas('screen.snapshot') && <button onClick={() => void action(() => file('screen.snapshot', {}, true))}>Capture screen</button>}
      </div></details>}
      {(guestHas('clipboard.read') || guestHas('clipboard.write')) && <details><summary>Clipboard</summary><textarea value={text} maxLength={4096} aria-label="Device clipboard text" onChange={(event) => setText(event.target.value)} />
        {guestHas('clipboard.read') && <button onClick={() => void action(async () => { const result = await operations.call<{ text: string }>('clipboard.read'); if (mounted.current) setText(result.text) })}>Read clipboard</button>}
        {guestHas('clipboard.write') && <button onClick={command('clipboard.write', { text })}>Write clipboard</button>}</details>}
      {(guestHas('apps.list') || guestHas('apps.launch') || guestHas('apps.open_url')) && <details><summary>Applications</summary>
        {guestHas('apps.list') && <button onClick={command('apps.list')}>List applications</button>}
        {guestHas('apps.launch') && <><label>Bundle ID <input value={bundle} onChange={(event) => setBundle(event.target.value)} /></label><button onClick={command('apps.launch', { bundle })}>Launch</button></>}
        {guestHas('apps.open_url') && <><label>Web link <input type="url" value={url} onChange={(event) => setURL(event.target.value)} /></label><button onClick={command('apps.open_url', { url })}>Open link</button></>}
      </details>}
      {(guestHas('audio.playback.listen') || guestHas('audio.microphone.listen') || guestHas('talk.speaker') || guestHas('talk.virtual_microphone') || guestHas('audio.microphone.record') || guestHas('audio.output')) && <details><summary>Sound</summary>
        {guestHas('audio.playback.listen') && <button aria-pressed={listening} onClick={() => void action(() => listen(audio, 'audio.playback', listening, setListening))}>{listening ? 'Stop playback audio' : 'Listen to playback'}</button>}
        {guestHas('audio.microphone.listen') && <button aria-pressed={room} onClick={() => void action(() => listen(microphone, 'audio.microphone', room, setRoom))}>{room ? 'Stop microphone' : 'Listen to room microphone'}</button>}
        {guestHas('audio.output') && <><button onClick={command('audio.output', { enabled: false })}>Mute device output</button><button onClick={command('audio.output', { enabled: true })}>Restore device output</button></>}
        {guestHas('audio.microphone.record') && <button aria-pressed={recordingMic} onClick={() => void action(async () => { await operations.call('audio.record', { on: !recordingMic }); setRecordingMic(!recordingMic) })}>{recordingMic ? 'Stop microphone recording' : 'Record microphone (up to 5 minutes)'}</button>}
        {guestHas('capture.download') && guestHas('audio.microphone.record') && <button onClick={() => void action(() => file('capture.download', { kind: 'microphone' }))}>Download microphone recording</button>}
        {(guestHas('talk.speaker') || guestHas('talk.virtual_microphone')) && <><label>Talk output <select defaultValue={guestHas('talk.speaker') ? 'speaker' : 'mic'} onChange={(event) => void action(() => operations.call('talk.route', { mode: event.target.value }))}>
          {guestHas('talk.speaker') && <option value="speaker">Device speaker</option>}{guestHas('talk.virtual_microphone') && <option value="mic">App microphone</option>}{guestHas('talk.speaker') && guestHas('talk.virtual_microphone') && <option value="both">Both</option>}
        </select></label><button aria-pressed={talking} onClick={() => { if (talking) talk.stop(); else void talk.start() }}>{talking ? 'Stop talking' : 'Talk'}</button></>}
      </details>}
      {(guestHas('camera.snapshot') || guestHas('camera.record')) && <details><summary>Camera captures</summary>
        {guestHas('camera.snapshot') && <><label>Photo camera <select value={snapshotPosition} onChange={(event) => setSnapshotPosition(event.target.value)}><option value="back">Back</option><option value="front">Front</option></select></label><button onClick={() => void action(() => file('camera.snapshot', { position: snapshotPosition }, true))}>Take photo</button></>}
        {guestHas('camera.record') && <button aria-pressed={recordingCamera} onClick={() => void action(async () => { await operations.call('camera.record', { on: !recordingCamera }); setRecordingCamera(!recordingCamera) })}>{recordingCamera ? 'Stop camera recording' : 'Record camera (live view first, up to 5 minutes)'}</button>}
        {guestHas('capture.download') && guestHas('camera.record') && <button onClick={() => void action(() => file('capture.download', { kind: 'camera' }))}>Download camera recording</button>}
      </details>}
      {guestHas('input.text') && <details><summary>Type text</summary><label>Text (US keyboard, up to 256 characters)<textarea value={text} maxLength={256} onChange={(event) => setText(event.target.value)} /></label><button onClick={command('input.text', { text })}>Type on device</button></details>}
      {guestHas('automation.macros') && <details><summary>Input macros</summary><p>Playback uses only the touch and keyboard rights granted to this session.</p>
        <button onClick={() => { if (recordingMacro) { setMacro(engine.current?.recordStop() || []); setRecordingMacro(false) } else { engine.current?.recordStart(); setRecordingMacro(true) } }}>{recordingMacro ? 'Stop recording' : 'Record permitted input'}</button>
        <button disabled={!macro.length || recordingMacro} onClick={() => { if (playingMacro) { engine.current?.stopPlay(); setPlayingMacro(false) } else { setPlayingMacro(true); void engine.current?.play(macro, (state) => { if (mounted.current) setPlayingMacro(state !== 'idle') }) } }}>{playingMacro ? 'Stop playback' : `Play ${macro.length} events`}</button>
      </details>}
      {guestHas('media.browse') && <details><summary>Photos and videos</summary><button onClick={() => void action(() => loadMedia(0))}>Open library</button>
        <div className="guest-file-list">{media.map((item) => <div key={item.id}><span>{item.name} · {item.type}</span>
          {guestHas('media.preview') && <button onClick={() => void action(() => file('media.preview', { id: item.id }, true))}>Preview</button>}
          {guestHas('media.download') && <button onClick={() => void action(() => file('media.original', { id: item.id }))}>Download original</button>}
          {guestHas('media.download') && item.type==='video' && <button onClick={()=>void action(()=>file('media.original',{id:item.id},true,true))}>Play original video</button>}
          {guestHas('media.delete') && item.deletable && <button onClick={() => { if (confirm(`Move ${item.name} to Recently Deleted?`)) void action(async () => { await operations.confirmed('media.delete', { id: item.id }); await loadMedia(0) }) }}>Delete</button>}
        </div>)}</div>{cursor !== null && media.length > 0 && <button onClick={() => void action(() => loadMedia(cursor))}>Next page</button>}</details>}
      {(guestHas('files.list') || guestHas('files.upload')) && <details><summary>Exchange files</summary><p>Only the device’s exchange folder is available.</p>
        {guestHas('files.list') && <><button onClick={() => void action(() => loadFiles(''))}>Open folder</button>{path && <button onClick={() => void action(() => loadFiles(path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : ''))}>Parent folder</button>}<p>{path || '/'}</p>
          <div className="guest-file-list">{files.map((item) => <div key={item.name}><span>{item.name}{item.directory ? '/' : ` · ${item.size} bytes`}</span>
            {item.directory ? <button onClick={() => void action(() => loadFiles(childPath(item.name)))}>Open</button> : <>
              {guestHas('files.preview') && <button onClick={() => void action(async () => { const transfer = await operations.call<GuestTransfer>('files.preview', { path: childPath(item.name) }); const blob = await operations.read(transfer, 2 * 1024 * 1024, abort.current.signal); if (mounted.current) setOutput(await blob.text()) })}>Preview text</button>}
              {guestHas('files.download') && <button onClick={() => void action(() => file('files.open', { path: childPath(item.name) }))}>Download</button>}
              {guestHas('files.delete') && <button onClick={() => { if (confirm(`Delete ${item.name}?`)) void action(async () => { await operations.confirmed('files.delete', { path: childPath(item.name) }); await loadFiles() }) }}>Delete</button>}
            </>}
          </div>)}</div></>}
        {guestHas('files.upload') && <><label>Upload to this folder <input type="file" onChange={(event) => { const upload = event.target.files?.[0]; event.target.value = ''; if (upload) void action(async () => { await operations.upload(upload, childPath(upload.name), overwrite, abort.current.signal, setProgress); if (guestHas('files.list')) await loadFiles() }) }} /></label>
          {guestHas('files.overwrite') && <label><input type="checkbox" checked={overwrite} onChange={(event) => setOverwrite(event.target.checked)} />Replace an existing file</label>}</>}
      </details>}
      {guestHas('system.inventory') && <details><summary>Packages and tweaks</summary><button onClick={()=>void action(()=>loadInventory('packages'))}>Packages</button><button onClick={()=>void action(()=>loadInventory('tweaks'))}>Tweaks</button>{inventory?.next!==null&&inventory&&<button onClick={()=>void action(()=>loadInventory(inventory.kind,inventory.next!))}>Next {inventory.kind}</button>}</details>}
      {(guestHas('system.tweak_toggle') || guestHas('system.package_download') || guestHas('system.package_remove') || guestHas('system.respring')) && <details><summary>System actions</summary>
        {(guestHas('system.tweak_toggle') || guestHas('system.package_download')) && <><label>Tweak name <input value={bundle} onChange={(event) => setBundle(event.target.value)} /></label>
          {guestHas('system.package_download') && <button onClick={() => void action(() => file('system.package_download', { name: bundle }))}>Download tweak library</button>}
          {guestHas('system.tweak_toggle') && <>{[true, false].map((enabled) => <button key={String(enabled)} onClick={() => { if (confirm(`${enabled ? 'Enable' : 'Disable'} ${bundle}?`)) void action(() => operations.confirmed('system.tweak_toggle', { name: bundle, enabled })) }}>{enabled ? 'Enable tweak' : 'Disable tweak'}</button>)}</>}
        </>}
        {guestHas('system.package_remove') && <><label>Installed package ID <input value={bundle} onChange={(event) => setBundle(event.target.value)} /></label><button onClick={() => { if (confirm(`Remove installed package ${bundle}?`)) void action(() => operations.confirmed('system.package_remove', { id: bundle })) }}>Remove package</button></>}
        {guestHas('system.respring') && <button onClick={() => { if (confirm('Restart SpringBoard? This disconnects device control.')) void action(() => operations.confirmed('system.respring')) }}>Restart SpringBoard</button>}
      </details>}
      {guestHas('terminal.root') && <details><summary>Root terminal</summary><p>This grants full device authority. Commands may create persistent changes.</p><button onClick={() => setTerminal(!terminal)}>{terminal ? 'Close terminal' : 'Open terminal'}</button></details>}
    </fieldset>
    {progress !== null && <progress value={progress} max="1" aria-label="Upload progress" />}
    {busy && <button onClick={() => { abort.current.abort(); abort.current = new AbortController() }}>Cancel transfer</button>}
    {error && <p role="alert">{error}</p>}
    {output && <details open><summary>Result</summary><GuestResult value={output}/></details>}
    {preview && <div><button onClick={() => { URL.revokeObjectURL(preview); urls.current.delete(preview); setPreview('') }}>Close preview</button>{(previewCapture?guestHas('capture.download'):guestHas('media.download'))&&<a href={preview} download={previewName}>Save displayed capture</a>}{previewVideo?<video src={preview} controls playsInline className="guest-preview"/>:<img src={preview} alt="Device capture or media preview" className="guest-preview" />}</div>}
    {guestHas('input.pointer')&&ready&&<GuestPointer operations={operations} onError={setError}/>}
    {guestHas('camera.live') && <GuestCamera operations={operations} />}
    {terminal && <GuestTerminal operations={operations} onError={setError} />}
  </div>
}
