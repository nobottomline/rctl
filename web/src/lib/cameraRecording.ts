import muxjs from 'mux.js'

interface TransmuxedSegment {
  initSegment: Uint8Array
  data: Uint8Array
}

export async function cameraRecordingToMp4(recording: Blob): Promise<Blob> {
  const source = new Uint8Array(await recording.arrayBuffer())
  if (source.byteLength === 0) throw new Error('Camera recording is empty')

  const parts: Uint8Array[] = []
  const transmuxer = new muxjs.mp4.Transmuxer({ keepOriginalTimestamps: false })
  transmuxer.on('data', (segment: TransmuxedSegment) => {
    parts.push(new Uint8Array(segment.initSegment), new Uint8Array(segment.data))
  })
  transmuxer.push(source)
  transmuxer.flush()

  if (parts.length === 0) {
    throw new Error('Camera recording contains no complete H.264 frames')
  }
  return new Blob(parts, { type: 'video/mp4' })
}
