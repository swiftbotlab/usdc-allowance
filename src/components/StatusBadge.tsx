import React from 'react'
import { STATUS_COLORS, STATUS_LABELS } from '../lib/format'

interface Props { status: number; className?: string }

export function StatusBadge({ status, className = '' }: Props) {
  return (
    <span className={`inline-flex items-center text-xs font-semibold px-2 py-0.5 rounded-full ${STATUS_COLORS[status] ?? 'bg-gray-100 text-gray-500'} ${className}`}>
      {STATUS_LABELS[status] ?? 'Unknown'}
    </span>
  )
}
