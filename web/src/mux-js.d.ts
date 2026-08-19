declare module 'mux.js' {
  interface TransmuxerOptions {
    keepOriginalTimestamps?: boolean
  }

  interface TransmuxedSegment {
    initSegment: Uint8Array
    data: Uint8Array
  }

  class Transmuxer {
    constructor(options?: TransmuxerOptions)
    on(event: 'data', callback: (segment: TransmuxedSegment) => void): void
    push(data: Uint8Array): void
    flush(): void
  }

  const muxjs: {
    mp4: {
      Transmuxer: typeof Transmuxer
    }
  }

  export default muxjs
}
