import { useEffect, useState } from 'react'
import { TriangleAlert } from 'lucide-react'
import { compatibilityWarning, loadDeviceCapabilities } from '../lib/capabilities'

export default function CompatibilityBanner() {
  const [warning, setWarning] = useState('')

  useEffect(() => {
    let active = true
    loadDeviceCapabilities().then((capabilities) => {
      if (active && capabilities) setWarning(compatibilityWarning(capabilities))
    })
    return () => {
      active = false
    }
  }, [])

  if (!warning) return null
  return (
    <div className="fixed inset-x-3 top-9 z-50 mx-auto flex max-w-xl items-center gap-2 rounded-lg bg-amber-500 px-3 py-2 text-[12px] font-medium text-black shadow-xl">
      <TriangleAlert className="size-4 shrink-0" />
      <span>{warning}</span>
    </div>
  )
}
