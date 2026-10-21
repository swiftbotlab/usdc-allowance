import { useEffect, useState } from 'react'

/** Returns seconds remaining until `targetTimestamp` (unix seconds). Ticks every second. */
export function useCountdown(targetTimestamp: number | bigint | undefined, onZero?: () => void): number {
  const target = targetTimestamp !== undefined ? Number(targetTimestamp) : 0

  const calc = () => Math.max(0, target - Math.floor(Date.now() / 1000))
  const [remaining, setRemaining] = useState<number>(calc)

  useEffect(() => {
    if (!target) return
    setRemaining(calc())
    const id = setInterval(() => {
      const r = calc()
      setRemaining(r)
      if (r === 0) {
        clearInterval(id)
        onZero?.()
      }
    }, 1000)
    return () => clearInterval(id)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target])

  return remaining
}
