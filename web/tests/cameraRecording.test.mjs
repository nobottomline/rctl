import test from 'node:test'
import assert from 'node:assert/strict'
import muxjs from 'mux.js'
import { cameraRecordingToMp4 } from '../src/lib/cameraRecording.ts'

test('camera recording rejects empty input', async () => {
  await assert.rejects(cameraRecordingToMp4(new Blob()), /empty/)
})

test('camera recording rejects input without complete frames', async () => {
  await assert.rejects(cameraRecordingToMp4(new Blob([new Uint8Array([0, 1, 2])])), /no complete/)
})

test('camera recording copies segment views before muxer buffers are reused', async t => {
  const original = muxjs.mp4.Transmuxer
  t.after(() => { muxjs.mp4.Transmuxer = original })
  muxjs.mp4.Transmuxer = class {
    on(event, callback) { assert.equal(event, 'data'); this.emit = callback }
    push(source) { assert.deepEqual([...source], [7]) }
    flush() {
      for (const BufferType of [ArrayBuffer, SharedArrayBuffer]) {
        const buffer = new Uint8Array(new BufferType(6))
        buffer.set([99, 1, 2, 3, 4, 99])
        this.emit({ initSegment: buffer.subarray(1, 3), data: buffer.subarray(3, 5) })
        buffer.fill(0)
      }
    }
  }
  const result = await cameraRecordingToMp4(new Blob([new Uint8Array([7])]))
  assert.equal(result.type, 'video/mp4')
  assert.deepEqual([...new Uint8Array(await result.arrayBuffer())], [1, 2, 3, 4, 1, 2, 3, 4])
})
