import React from 'react'
import { ExternalLink } from 'lucide-react'
import { shortAddr } from '../lib/format'
import { useNetwork } from '../hooks/useNetwork'

interface AddrProps {
  address: string
  className?: string
  shorten?: boolean
}

export function AddressLink({ address, className = '', shorten = true }: AddrProps) {
  const { cfg } = useNetwork()
  const href = `${cfg.explorerBase}/address/${address}`
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={`inline-flex items-center gap-1 font-mono text-xs text-red-600 hover:text-red-800 break-all ${className}`}
    >
      {shorten ? shortAddr(address) : address}
      <ExternalLink className="w-3 h-3 shrink-0" />
    </a>
  )
}

interface TxProps {
  hash: string
  label?: string
  className?: string
}

export function TxLink({ hash, label, className = '' }: TxProps) {
  const { cfg } = useNetwork()
  const href = `${cfg.explorerBase}/tx/${hash}`
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={`inline-flex items-center gap-1 text-xs text-red-600 hover:text-red-800 ${className}`}
    >
      {label ?? shortAddr(hash)}
      <ExternalLink className="w-3 h-3 shrink-0" />
    </a>
  )
}
