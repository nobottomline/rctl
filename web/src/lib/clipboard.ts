// Text copying can still work on trusted LAN HTTP, unlike image clipboard APIs.
export async function copyText(text: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(text); return true } catch { /* try the synchronous fallback */ }
  }
  const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
  const selection = document.getSelection()
  const ranges = selection ? Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange()) : []
  const field = document.createElement('textarea')
  field.value = text
  field.readOnly = true
  field.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none'
  document.body.appendChild(field)
  try {
    field.focus({ preventScroll: true })
    field.select()
    return document.execCommand('copy')
  } catch { return false }
  finally {
    field.remove()
    previous?.focus({ preventScroll: true })
    selection?.removeAllRanges()
    for (const range of ranges) selection?.addRange(range)
  }
}
