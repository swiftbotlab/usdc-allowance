import React from 'react'
import { fmtUsdc, fmtCountdown, pct } from '../lib/format'
import { useCountdown } from '../hooks/useCountdown'

interface Props {
  spentInPeriod: bigint
  periodCap: bigint
  balance: bigint
  remainingInPeriod: bigint
  maxPayment: bigint
  periodEnd: bigint
  onReset?: () => void
}

export function BudgetBar({ spentInPeriod, periodCap, balance, remainingInPeriod, maxPayment, periodEnd, onReset }: Props) {
  const secs = useCountdown(periodEnd, onReset)
  const usedPct = pct(spentInPeriod, periodCap)

  return (
    <div className="bg-white rounded-xl border border-gray-200 p-5 space-y-4">
      {/* Big remaining number */}
      <div>
        <p className="text-xs font-semibold uppercase tracking-wider text-gray-400 mb-1">Left this period</p>
        <p className="text-4xl font-bold text-gray-900 tabular-nums tracking-tight">
          {fmtUsdc(remainingInPeriod)}
          <span className="text-lg font-normal text-gray-400 ml-1">USDC</span>
        </p>
      </div>

      {/* Progress bar */}
      <div>
        <div className="flex justify-between text-xs text-gray-500 mb-1">
          <span>{fmtUsdc(spentInPeriod)} spent</span>
          <span>{fmtUsdc(periodCap)} cap</span>
        </div>
        <div className="h-2 bg-gray-100 rounded-full overflow-hidden">
          <div
            className="h-full bg-red-500 rounded-full transition-all"
            style={{ width: `${usedPct}%` }}
          />
        </div>
        <p className="text-xs text-gray-400 mt-1">Resets in {fmtCountdown(secs)}</p>
      </div>

      {/* Stats row */}
      <div className="grid grid-cols-2 gap-3 pt-1 border-t border-gray-100">
        <Stat label="Max single payment" value={`${fmtUsdc(maxPayment)} USDC`} />
        <Stat label="Balance" value={`${fmtUsdc(balance)} USDC`} />
      </div>
    </div>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-gray-400">{label}</p>
      <p className="text-sm font-semibold text-gray-800 tabular-nums">{value}</p>
    </div>
  )
}
