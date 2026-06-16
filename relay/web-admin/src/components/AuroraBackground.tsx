// Minimal, GPU-cheap ambient background: a few large, heavily-blurred light
// blooms that drift slowly (an "aurora"). Pure CSS — no WebGL/Three.js. Honors
// prefers-reduced-motion (the blooms hold still).
export function AuroraBackground() {
  return (
    <div aria-hidden className="pointer-events-none fixed inset-0 overflow-hidden">
      <div className="aurora-blob aurora-a" />
      <div className="aurora-blob aurora-b" />
      <div className="aurora-blob aurora-c" />
      {/* keep the centre calm + readable */}
      <div className="absolute inset-0 bg-[radial-gradient(130%_110%_at_50%_42%,transparent_38%,var(--color-bg)_100%)]" />
    </div>
  )
}
