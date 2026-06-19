// RTP video probe — paste into the console of a logged-in /admin tab on the relay.
// rctld is now the offerer: it offers a send-only H.264 RTP track, the browser
// answers and renders it natively in a floating <video> (jitter buffer + NACK).
//
// Auto-discovers the first online+approved device. Call __rtpStats() any time to
// read framesDecoded / keyFramesDecoded / pliCount / framesDropped. __rtpStop()
// tears it down.
(async () => {
  const wsScheme = location.protocol === 'https:' ? 'wss' : 'ws';
  let deviceID = window.__rtpDeviceID;
  if (!deviceID) {
    const r = await fetch('/api/admin/devices', { credentials: 'include' });
    const list = await r.json();
    const arr = Array.isArray(list) ? list : (list.devices || []);
    const pick = arr.find(d => d.online && (d.status === 'approved' || d.approved_at)) || arr.find(d => d.online) || arr[0];
    if (!pick) { console.error('[rtp] no devices found'); return; }
    deviceID = pick.id;
  }
  console.log('[rtp] device', deviceID);

  const pc = new RTCPeerConnection({});
  const pend = []; let remoteReady = false;

  const v = document.createElement('video');
  v.autoplay = true; v.playsInline = true; v.muted = true;
  v.style.cssText = 'position:fixed;right:16px;bottom:16px;width:480px;z-index:2147483647;' +
    'border:2px solid #c25e3a;border-radius:10px;background:#000;box-shadow:0 8px 30px rgba(0,0,0,.5)';
  document.body.appendChild(v);

  const hud = document.createElement('div');
  hud.style.cssText = 'position:fixed;right:16px;bottom:336px;z-index:2147483647;color:#d6d8de;' +
    'font:12px ui-monospace,Menlo,monospace;background:#0e0f13cc;padding:4px 8px;border-radius:6px';
  hud.textContent = 'connecting…'; document.body.appendChild(hud);

  pc.ontrack = e => { v.srcObject = e.streams[0] || new MediaStream([e.track]); };
  pc.oniceconnectionstatechange = () => console.log('[rtp] ice', pc.iceConnectionState);
  pc.onconnectionstatechange = () => { hud.textContent = pc.connectionState; console.log('[rtp] pc', pc.connectionState); };

  const ws = new WebSocket(`${wsScheme}://${location.host}/signal/devices/${deviceID}`);
  pc.onicecandidate = e => {
    if (e.candidate && ws.readyState === 1)
      ws.send(JSON.stringify({ kind: 'candidate', payload: { candidate: e.candidate.candidate, mid: e.candidate.sdpMid } }));
  };
  ws.onopen = () => console.log('[rtp] signal ws open');
  ws.onclose = () => console.log('[rtp] signal ws closed');
  ws.onmessage = async ev => {
    const m = JSON.parse(ev.data);
    if (m.kind === 'offer') {
      await pc.setRemoteDescription({ type: 'offer', sdp: m.payload.sdp });
      remoteReady = true;
      for (const c of pend.splice(0)) { try { await pc.addIceCandidate(c); } catch {} }
      const a = await pc.createAnswer(); await pc.setLocalDescription(a);
      ws.send(JSON.stringify({ kind: 'answer', payload: { sdp: pc.localDescription.sdp } }));
      console.log('[rtp] answered');
    } else if (m.kind === 'candidate') {
      const ic = { candidate: (m.payload.candidate || '').replace(/^a=/, ''), sdpMid: m.payload.mid || '0' };
      if (remoteReady) { try { await pc.addIceCandidate(ic); } catch {} } else pend.push(ic);
    }
  };

  window.__rtpStats = async () => {
    const s = await pc.getStats(); let o = { pc: pc.connectionState };
    s.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'video')
      o = { ...o, packets: r.packetsReceived, bytes: r.bytesReceived, frames: r.framesDecoded,
            kf: r.keyFramesDecoded, pli: r.pliCount, nack: r.nackCount, drop: r.framesDropped,
            wh: `${r.frameWidth}x${r.frameHeight}`, fps: r.framesPerSecond, dec: r.decoderImplementation }; });
    console.table(o); return o;
  };
  window.__rtpStop = () => { try { ws.close(); } catch {} try { pc.close(); } catch {} v.remove(); hud.remove(); console.log('[rtp] stopped'); };
  setInterval(() => { if (v.videoWidth) hud.textContent = `${pc.connectionState} · ${v.videoWidth}x${v.videoHeight}`; }, 1000);
})();
