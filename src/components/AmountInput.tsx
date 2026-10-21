import React from 'react'

interface Props {
  label: string
  value: string
  onChange: (v: string) => void
  placeholder?: string
  hint?: string
  disabled?: boolean
  min?: string
}

export function AmountInput({ label, value, onChange, placeholder = '0', hint, disabled, min }: Props) {
  return (
    <div className="flex flex-col gap-1">
      <label className="text-sm font-medium text-gray-700">{label}</label>
      <div className="relative">
        <input
          type="number"
          inputMode="decimal"
          step="any"
          min={min}
          value={value}
          onChange={e => onChange(e.target.value)}
          placeholder={placeholder}
          disabled={disabled}
          className="w-full pr-16 pl-3 py-2.5 border border-gray-300 rounded-lg text-sm tabular-nums focus:outline-none focus:ring-2 focus:ring-red-500 focus:border-transparent disabled:bg-gray-50 disabled:text-gray-400"
        />
        <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold text-gray-400 pointer-events-none">
          USDC
        </span>
      </div>
      {hint && <p className="text-xs text-gray-500">{hint}</p>}
    </div>
  )
}
