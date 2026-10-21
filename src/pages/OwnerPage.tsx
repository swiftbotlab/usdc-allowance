import React, { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount, useReadContract } from 'wagmi'
import { Plus, Search } from 'lucide-react'
import { useNetwork } from '../hooks/useNetwork'
import { USDC_ALLOWANCE_ABI } from '../config/abi'
import { fmtUsdc, pct, shortAddr } from '../lib/format'
import { StatusBadge } from '../components/StatusBadge'
import { useCountdown } from '../hooks/useCountdown'

export function OwnerPage() {
  const { address, isConnected } = useAccount()
  const { network, cfg } = useNetwork()
  const [lookupId, setLookupId] = useState('')

  const { data: ids } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'idsByOwner',
    args: [address ?? '0x0000000000000000000000000000000000000000'],
    chainId: cfg.chain.id,
    query: { enabled: isConnected && !!address },
  })

  const handleLookup = (e: React.FormEvent) => {
    e.preventDefault()
    const n = parseInt(lookupId)
    if (n >= 1) window.location.hash = `#/${network}/a/${n}`
  }

  return (
    <div className="max-w-2xl mx-auto px-4 py-8 space-y-10">
      {/* Hero */}
      <div className="space-y-3">
        <h1 className="text-3xl font-bold text-gray-900 tracking-tight">
          Spending limits for software that pays
        </h1>
        <p className="text-gray-500 text-base max-w-lg">
          Give an AI agent or backend service a USDC budget, not your wallet.
          The contract enforces every rule — caps, payee lists, expiry — on every payment.
        </p>
      </div>

      {/* How it works */}
      <div className="grid sm:grid-cols-3 gap-4">
        {[
          {
            n: '01',
            title: 'Fund an allowance',
            body: 'Deposit native USDC and set a per-payment cap, a period cap, an expiry, and optionally a payee allowlist.',
          },
          {
            n: '02',
            title: 'The contract checks every payment',
            body: 'Per-payment cap, period cap, payee allowlist, expiry, and pause are all enforced on-chain before any funds move.',
          },
          {
            n: '03',
            title: 'Tighten instantly, loosen later',
            body: 'Tighter limits apply immediately. Looser ones wait for the loosen delay. Revoke returns remaining funds at any time.',
          },
        ].map(s => (
          <div key={s.n} className="bg-white rounded-xl border border-gray-200 p-5 space-y-2">
            <span className="text-xs font-bold text-red-500 tracking-widest">{s.n}</span>
            <h3 className="font-semibold text-gray-900 text-sm">{s.title}</h3>
            <p className="text-xs text-gray-500 leading-relaxed">{s.body}</p>
          </div>
        ))}
      </div>

      {/* Actions */}
      <div className="flex flex-wrap gap-3 items-start">
        <Link
          to={`/${network}/new`}
          className="inline-flex items-center gap-2 bg-red-600 text-white text-sm font-semibold px-4 py-2.5 rounded-lg hover:bg-red-700 transition-colors min-h-[44px]"
        >
          <Plus className="w-4 h-4" />
          New allowance
        </Link>

        <form onSubmit={handleLookup} className="flex gap-2">
          <input
            type="number"
            min="1"
            value={lookupId}
            onChange={e => setLookupId(e.target.value)}
            placeholder="Look up allowance #"
            className="text-sm border border-gray-300 rounded-lg px-3 py-2.5 focus:outline-none focus:ring-2 focus:ring-red-500 w-44"
          />
          <button
            type="submit"
            className="p-2.5 bg-gray-100 rounded-lg hover:bg-gray-200 transition-colors"
          >
            <Search className="w-4 h-4 text-gray-600" />
          </button>
        </form>
      </div>

      {/* My allowances */}
      {isConnected && (
        <div className="space-y-3">
          <h2 className="font-semibold text-gray-900">My allowances</h2>
          {(!ids || ids.length === 0) ? (
            <p className="text-sm text-gray-400">No allowances yet — create your first one above.</p>
          ) : (
            <div className="space-y-3">
              {[...ids].reverse().map(id => (
                <AllowanceCard key={id.toString()} id={id} network={network} cfg={cfg} />
              ))}
            </div>
          )}
        </div>
      )}

      {!isConnected && (
        <p className="text-sm text-gray-400">Connect your wallet to see your allowances.</p>
      )}
    </div>
  )
}

function AllowanceCard({ id, network, cfg }: { id: bigint; network: string; cfg: ReturnType<typeof useNetwork>['cfg'] }) {
  const { data: allowance } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'getAllowance',
    args: [id],
    chainId: cfg.chain.id,
  })

  const { data: budgetData } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'budget',
    args: [id],
    chainId: cfg.chain.id,
    query: { refetchInterval: 15000 },
  })

  const { data: label } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'labelOf',
    args: [id],
    chainId: cfg.chain.id,
  })

  const secs = useCountdown(budgetData?.periodEnd)
  const usedPct = allowance ? pct(budgetData?.spentInPeriod ?? 0n, allowance.periodCap) : 0

  if (!allowance) return (
    <div className="bg-white rounded-xl border border-gray-200 p-5 animate-pulse h-24" />
  )

  return (
    <Link
      to={`/${network}/a/${id}`}
      className="block bg-white rounded-xl border border-gray-200 p-5 hover:border-red-300 hover:shadow-sm transition-all space-y-3"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="text-xs text-gray-400 font-mono">#{id.toString()}</span>
            {label && <span className="text-sm font-semibold text-gray-900 truncate">{label}</span>}
          </div>
          <div className="flex items-center gap-1 mt-0.5">
            <span className="text-xs text-gray-400">Spender:</span>
            <span className="text-xs font-mono text-gray-600">{shortAddr(allowance.spender)}</span>
          </div>
        </div>
        <StatusBadge status={budgetData?.status ?? 0} />
      </div>

      {/* Balance and period bar */}
      <div className="space-y-1.5">
        <div className="flex justify-between text-xs text-gray-500">
          <span>{fmtUsdc(budgetData?.spentInPeriod)} / {fmtUsdc(allowance.periodCap)} USDC this period</span>
          {budgetData?.status === 1 && <span className="text-gray-400">resets {formatCountdownShort(secs)}</span>}
        </div>
        <div className="h-1.5 bg-gray-100 rounded-full overflow-hidden">
          <div className="h-full bg-red-500 rounded-full" style={{ width: `${usedPct}%` }} />
        </div>
        <div className="text-xs text-gray-400">
          Balance: {fmtUsdc(allowance.balance)} USDC &middot;
          Expires {new Date(Number(allowance.expiresAt) * 1000).toLocaleDateString()}
        </div>
      </div>
    </Link>
  )
}

function formatCountdownShort(secs: number) {
  if (secs < 60) return `in ${secs}s`
  if (secs < 3600) return `in ${Math.floor(secs / 60)}m`
  return `in ${Math.floor(secs / 3600)}h`
}
