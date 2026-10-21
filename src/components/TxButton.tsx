import React, { type ReactNode } from 'react'
import { Loader2 } from 'lucide-react'

interface Props {
  onClick: () => void
  disabled?: boolean
  isPending?: boolean
  isConfirming?: boolean
  children: ReactNode
  variant?: 'primary' | 'danger' | 'ghost'
  className?: string
}

export function TxButton({
  onClick, disabled, isPending, isConfirming, children, variant = 'primary', className = '',
}: Props) {
  const busy = isPending || isConfirming
  const base = 'inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-lg text-sm font-semibold transition-colors min-h-[44px] disabled:opacity-50 disabled:cursor-not-allowed'
  const variants = {
    primary: 'bg-red-600 text-white hover:bg-red-700',
    danger:  'bg-red-100 text-red-700 hover:bg-red-200',
    ghost:   'bg-gray-100 text-gray-700 hover:bg-gray-200',
  }

  return (
    <button
      onClick={onClick}
      disabled={disabled || busy}
      className={`${base} ${variants[variant]} ${className}`}
    >
      {busy && <Loader2 className="w-4 h-4 animate-spin" />}
      {isPending ? 'Waiting for wallet…' : isConfirming ? 'Confirming…' : children}
    </button>
  )
}
