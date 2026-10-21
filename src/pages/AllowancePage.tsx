import React, { useState, useEffect, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useSwitchChain } from 'wagmi'
import { parseEther, keccak256, toBytes, createPublicClient, http as httpTransport } from 'viem'
import { toast } from 'sonner'
import { Trash2 } from 'lucide-react'
import { useNetwork } from '../hooks/useNetwork'
import { USDC_ALLOWANCE_ABI } from '../config/abi'
import { fmtUsdc, fmtCountdown, shortAddr, shortBytes32, CAN_PAY_REASONS } from '../lib/format'
import { getDynamicMaxFee, PRIORITY_FEE } from '../lib/gas'

import { StatusBadge } from '../components/StatusBadge'
import { BudgetBar } from '../components/BudgetBar'
import { AddressLink, TxLink } from '../components/ExplorerLink'
import { TxButton } from '../components/TxButton'
import { AmountInput } from '../components/AmountInput'
import { useCountdown } from '../hooks/useCountdown'

// MAX_FEE is now fetched dynamically per-transaction via getDynamicMaxFee()

export function AllowancePage() {
  const { id: idStr } = useParams<{ id: string }>()
  const { network, cfg } = useNetwork()
  const { address, isConnected, chainId } = useAccount()
  const { switchChain } = useSwitchChain()

  // Validate id
  const validId = /^[1-9]\d*$/.test(idStr ?? '') ? BigInt(idStr!) : null

  const { data: allowanceCount } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'allowanceCount',
    chainId: cfg.chain.id,
  })

  const idOutOfRange = validId !== null && allowanceCount !== undefined && validId > allowanceCount

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'getAllowance',
    args: [validId ?? 0n],
    chainId: cfg.chain.id,
    query: { enabled: !!validId && !idOutOfRange },
  })

  const { data: budgetData, refetch: refetchBudget } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'budget',
    args: [validId ?? 0n],
    chainId: cfg.chain.id,
    query: {
      enabled: !!validId && !idOutOfRange,
      refetchInterval: 15000,
    },
  })

  const { data: labelStr } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'labelOf',
    args: [validId ?? 0n],
    chainId: cfg.chain.id,
    query: { enabled: !!validId },
  })

  const { data: pending } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'pendingLimits',
    args: [validId ?? 0n],
    chainId: cfg.chain.id,
    query: { enabled: !!validId, refetchInterval: 15000 },
  })

  const { data: payeesData, refetch: refetchPayees } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'getPayees',
    args: [validId ?? 0n],
    chainId: cfg.chain.id,
    query: { enabled: !!validId },
  })

  const refetch = () => { void refetchAllowance(); void refetchBudget(); void refetchPayees() }

  const isOwner   = isConnected && address?.toLowerCase() === allowance?.owner?.toLowerCase()
  const isSpender = isConnected && address?.toLowerCase() === allowance?.spender?.toLowerCase()

  if (!validId || idOutOfRange) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16 text-center">
        <p className="text-gray-400 text-sm">Allowance not found.</p>
      </div>
    )
  }

  if (!allowance) {
    return <div className="max-w-2xl mx-auto px-4 py-8">
      <div className="h-40 bg-white rounded-xl border border-gray-200 animate-pulse" />
    </div>
  }

  if (allowance.owner === '0x0000000000000000000000000000000000000000') {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16 text-center">
        <p className="text-gray-400 text-sm">Allowance not found.</p>
      </div>
    )
  }

  return (
    <div className="max-w-2xl mx-auto px-4 py-8 space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <span className="text-xs text-gray-400 font-mono">#{validId.toString()}</span>
            {labelStr && <h1 className="text-2xl font-bold text-gray-900">{labelStr}</h1>}
          </div>
          <div className="flex flex-wrap gap-4 mt-1 text-xs text-gray-500">
            <span>Owner: <AddressLink address={allowance.owner} /></span>
            <span>Spender: <AddressLink address={allowance.spender} /></span>
          </div>
        </div>
        <StatusBadge status={budgetData?.status ?? 0} className="shrink-0" />
      </div>

      {/* Budget bar */}
      {budgetData && budgetData.status === 1 && (
        <BudgetBar
          spentInPeriod={budgetData.spentInPeriod}
          periodCap={budgetData.periodCap}
          balance={budgetData.balance}
          remainingInPeriod={budgetData.remainingInPeriod}
          maxPayment={budgetData.maxPayment}
          periodEnd={budgetData.periodEnd}
          onReset={refetch}
        />
      )}

      {/* Info grid */}
      <div className="bg-white rounded-xl border border-gray-200 p-5 grid grid-cols-2 sm:grid-cols-3 gap-4">
        <InfoItem label="Balance" value={`${fmtUsdc(allowance.balance)} USDC`} />
        <InfoItem label="Per-payment cap" value={`${fmtUsdc(allowance.perPaymentCap)} USDC`} />
        <InfoItem label="Period cap" value={`${fmtUsdc(allowance.periodCap)} USDC`} />
        <InfoItem label="Expiry" value={new Date(Number(allowance.expiresAt) * 1000).toLocaleString()} />
        <InfoItem label="Total funded" value={`${fmtUsdc(allowance.totalFunded)} USDC`} />
        <InfoItem label="Total paid" value={`${fmtUsdc(allowance.totalPaid)} USDC`} />
        <InfoItem label="Payments" value={allowance.paymentCount.toString()} />
        <InfoItem label="Loosen delay" value={formatDelay(allowance.loosenDelay)} />
        <InfoItem label="Allowlist" value={allowance.useAllowlist ? 'Enabled' : 'Disabled'} />
      </div>

      {/* Pending limits banner */}
      {pending && pending.activeAt !== 0n && (
        <PendingBanner pending={pending} id={validId} cfg={cfg} chainId={chainId} onDone={refetch} isOwner={isOwner} switchChain={switchChain} allowance={allowance} />
      )}

      {/* Payees */}
      {allowance.useAllowlist && payeesData && (
        <PayeesSection
          id={validId}
          payees={payeesData[0]}
          activeAts={payeesData[1]}
          isOwner={isOwner}
          cfg={cfg}
          chainId={chainId}
          onDone={refetch}
          switchChain={switchChain}
        />
      )}

      {/* Owner actions */}
      {isOwner && (
        <OwnerActions
          id={validId}
          allowance={allowance}
          budgetData={budgetData}
          cfg={cfg}
          chainId={chainId}
          switchChain={switchChain}
          onDone={refetch}
        />
      )}

      {/* Spender pay form */}
      {isSpender && budgetData && (
        <SpenderPayForm
          id={validId}
          allowance={allowance}
          budgetData={budgetData}
          payeesData={payeesData}
          cfg={cfg}
          chainId={chainId}
          switchChain={switchChain}
          onDone={refetch}
        />
      )}

      {/* History */}
      <HistorySection id={validId} cfg={cfg} />
    </div>
  )
}

function InfoItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-gray-400">{label}</p>
      <p className="text-sm font-medium text-gray-800 tabular-nums">{value}</p>
    </div>
  )
}

function formatDelay(s: number): string {
  if (s === 0) return 'None'
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} h`
  return `${Math.floor(s / 86400)} d`
}

// ── Pending banner ────────────────────────────────────────────────────────────

function PendingBanner({ pending, id, cfg, chainId, onDone, isOwner, switchChain, allowance }: {
  pending: { perPaymentCap: bigint; periodCap: bigint; expiresAt: bigint; activeAt: bigint }
  id: bigint; cfg: ReturnType<typeof useNetwork>['cfg']; chainId: number | undefined
  onDone: () => void; isOwner: boolean; switchChain: ReturnType<typeof useSwitchChain>['switchChain']
  allowance: { perPaymentCap: bigint; periodCap: bigint; expiresAt: bigint }
}) {
  const secs = useCountdown(pending.activeAt)
  const activesAt = new Date(Number(pending.activeAt) * 1000)
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (isSuccess) { onDone(); toast.success('Pending change cancelled.') } }, [isSuccess])

  const cancel = async () => {
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    writeContract({
      address: cfg.address,
      abi: USDC_ALLOWANCE_ABI,
      functionName: 'setLimits',
      args: [id, allowance.perPaymentCap, allowance.periodCap, allowance.expiresAt],
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: PRIORITY_FEE,
      chainId: cfg.chain.id,
    })
  }

  return (
    <div className="bg-yellow-50 border border-yellow-200 rounded-xl p-4 space-y-1">
      <p className="text-sm font-medium text-yellow-800">Pending limit change</p>
      <p className="text-xs text-yellow-700">
        Per-payment cap: {fmtUsdc(allowance.perPaymentCap)} → {fmtUsdc(pending.perPaymentCap)} USDC &nbsp;·&nbsp;
        Period cap: {fmtUsdc(allowance.periodCap)} → {fmtUsdc(pending.periodCap)} USDC
      </p>
      <p className="text-xs text-yellow-600">
        Active at {activesAt.toLocaleTimeString()}{secs > 0 ? ` (in ${fmtCountdown(secs)})` : ' (now)'}
      </p>
      {isOwner && (
        <TxButton
          onClick={() => { void cancel() }}
          variant="ghost"
          isPending={isPending}
          isConfirming={isConfirming}
          className="mt-2 text-xs !py-1.5 !px-3 !min-h-0"
        >
          Cancel — keep current limits
        </TxButton>
      )}
    </div>
  )
}

// ── Payees ────────────────────────────────────────────────────────────────────

function PayeesSection({ id, payees, activeAts, isOwner, cfg, chainId, onDone, switchChain }: {
  id: bigint; payees: readonly `0x${string}`[]; activeAts: readonly bigint[]
  isOwner: boolean; cfg: ReturnType<typeof useNetwork>['cfg']; chainId: number | undefined
  onDone: () => void; switchChain: ReturnType<typeof useSwitchChain>['switchChain']
}) {
  const [newPayee, setNewPayee] = useState('')
  const { writeContract, data: addHash, isPending: addPending } = useWriteContract()
  const { isLoading: addConfirming, isSuccess: addSuccess } = useWaitForTransactionReceipt({ hash: addHash })
  const { writeContract: removeWc, data: rmHash, isPending: rmPending } = useWriteContract()
  const { isLoading: rmConfirming, isSuccess: rmSuccess } = useWaitForTransactionReceipt({ hash: rmHash })

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (addSuccess) { onDone(); toast.success('Payee added.') } }, [addSuccess])
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (rmSuccess) { onDone(); toast.success('Payee removed.') } }, [rmSuccess])

  const nowTs2 = Math.floor(Date.now() / 1000)

  const addPayee = async () => {
    if (!newPayee || !/^0x[0-9a-fA-F]{40}$/.test(newPayee)) { toast.error('Invalid address.'); return }
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    writeContract({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'addPayees',
      args: [id, [newPayee as `0x${string}`]],
      maxFeePerGas: maxFee, maxPriorityFeePerGas: PRIORITY_FEE, chainId: cfg.chain.id,
    })
    setNewPayee('')
  }

  const removePayee = async (p: `0x${string}`) => {
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    removeWc({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'removePayees',
      args: [id, [p]], maxFeePerGas: maxFee, maxPriorityFeePerGas: PRIORITY_FEE, chainId: cfg.chain.id,
    })
  }

  return (
    <div className="bg-white rounded-xl border border-gray-200 p-5 space-y-3">
      <h3 className="font-semibold text-gray-900 text-sm">Allowed payees</h3>
      {payees.length === 0 && <p className="text-xs text-gray-400">No payees listed yet.</p>}
      {payees.map((p, i) => {
        const activeAt = Number(activeAts[i])
        const active = activeAt <= nowTs2
        const secs = active ? 0 : activeAt - nowTs2
        return (
          <div key={p} className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-2 min-w-0">
              <AddressLink address={p} />
              {active
                ? <span className="text-xs text-green-600 font-medium">Active</span>
                : <span className="text-xs text-yellow-600">Active in {fmtCountdown(secs)}</span>}
            </div>
            {isOwner && (
              <button onClick={() => { void removePayee(p) }} className="p-1 text-gray-400 hover:text-red-600 transition-colors">
                <Trash2 className="w-3.5 h-3.5" />
              </button>
            )}
          </div>
        )
      })}
      {isOwner && payees.length < 20 && (
        <div className="flex gap-2 pt-2 border-t border-gray-100">
          <input
            type="text"
            value={newPayee}
            onChange={e => setNewPayee(e.target.value)}
            placeholder="0x…"
            className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500"
          />
          <TxButton onClick={() => { void addPayee() }} isPending={addPending} isConfirming={addConfirming} className="shrink-0">
            Add
          </TxButton>
        </div>
      )}
    </div>
  )
}

// ── Owner actions ─────────────────────────────────────────────────────────────

type AllowanceData = {
  owner: `0x${string}`; spender: `0x${string}`; perPaymentCap: bigint; periodCap: bigint
  balance: bigint; expiresAt: bigint; loosenDelay: number; [k: string]: unknown
}

function OwnerActions({ id, allowance, budgetData, cfg, chainId, switchChain, onDone }: {
  id: bigint; allowance: AllowanceData
  budgetData: { status: number; remainingInPeriod: bigint } | undefined
  cfg: ReturnType<typeof useNetwork>['cfg']; chainId: number | undefined
  switchChain: ReturnType<typeof useSwitchChain>['switchChain']; onDone: () => void
}) {
  const [fundAmt, setFundAmt] = useState('')
  const [withdrawAmt, setWithdrawAmt] = useState('')
  const [newPerCap, setNewPerCap] = useState(fmtUsdc(allowance.perPaymentCap))
  const [newPeriodCap, setNewPeriodCap] = useState(fmtUsdc(allowance.periodCap))
  const [newExpiry, setNewExpiry] = useState(
    new Date(Number(allowance.expiresAt) * 1000).toISOString().slice(0, 16)
  )
  const [showRevoke, setShowRevoke] = useState(false)

  const { writeContract, data: hash, isPending, reset } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  // eslint-disable-next-line react-hooks/exhaustive-deps, react/set-state-in-effect
  useEffect(() => {
    if (isSuccess) { onDone(); toast.success('Done!'); reset() }
  }, [isSuccess])

  const run = async (fn: string, args: unknown[], value?: bigint) => {
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    writeContract({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI,
      functionName: fn as 'fund',
      args: args as [bigint],
      ...(value ? { value } : {}),
      maxFeePerGas: maxFee,
      maxPriorityFeePerGas: PRIORITY_FEE,
      chainId: cfg.chain.id,
    })
  }

  // Fetch effectiveLimits — the values that pay() actually enforces right now
  const { data: effLimits } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'effectiveLimits',
    args: [id], chainId: cfg.chain.id,
    query: { refetchInterval: 15000 },
  })

  // Show whether each limit change is immediate or delayed
  // A change is "looser" if it exceeds the EFFECTIVE value (not just the stored value).
  const nowS = Math.floor(Date.now() / 1000)
  const newExpiryS = newExpiry ? Math.floor(new Date(newExpiry).getTime() / 1000) : 0
  const perCapBig = (() => { try { return parseEther(newPerCap) } catch { return null } })()
  const periodCapBig = (() => { try { return parseEther(newPeriodCap) } catch { return null } })()
  const delay = allowance.loosenDelay
  const effPerCap   = effLimits ? effLimits[0] : allowance.perPaymentCap
  const effPeriodCap = effLimits ? effLimits[1] : allowance.periodCap
  const effExpiresAt = effLimits ? Number(effLimits[2]) : Number(allowance.expiresAt)
  const perCapLooser   = perCapBig !== null && perCapBig > effPerCap
  const periodCapLooser = periodCapBig !== null && periodCapBig > effPeriodCap
  const expiryLooser   = newExpiryS > effExpiresAt
  const anyLooser = perCapLooser || periodCapLooser || expiryLooser

  // Per-field label: "applies now" vs "applies at HH:MM:SS"
  const appliesAtStr = (() => {
    if (delay <= 0 || !anyLooser) return null
    const t = new Date((nowS + delay) * 1000)
    return t.toLocaleTimeString()
  })()
  const perCapLabel    = perCapLooser && appliesAtStr ? `applies at ${appliesAtStr}` : 'applies now'
  const periodCapLabel = periodCapLooser && appliesAtStr ? `applies at ${appliesAtStr}` : 'applies now'
  const expiryLabel    = expiryLooser && appliesAtStr ? `applies at ${appliesAtStr}` : 'applies now'

  const changeNote = delay > 0 && anyLooser
    ? `Tighter fields apply immediately. Looser fields apply at ${appliesAtStr ?? '—'}.`
    : 'All changes apply immediately.'

  const isPaused = budgetData?.status === 2

  return (
    <div className="space-y-4">
      <h3 className="font-semibold text-gray-900">Owner actions</h3>

      {/* Top up */}
      <div className="bg-white rounded-xl border border-gray-200 p-4 space-y-3">
        <p className="text-sm font-medium text-gray-800">Top up</p>
        <AmountInput label="" value={fundAmt} onChange={setFundAmt} />
        <TxButton
          onClick={() => { const v = parseEther(fundAmt || '0'); if (v > 0n) void run('fund', [id], v) }}
          isPending={isPending} isConfirming={isConfirming}
        >Fund</TxButton>
      </div>

      {/* Withdraw */}
      <div className="bg-white rounded-xl border border-gray-200 p-4 space-y-3">
        <p className="text-sm font-medium text-gray-800">Withdraw</p>
        <p className="text-xs text-gray-400">Balance: {fmtUsdc(allowance.balance)} USDC</p>
        <AmountInput label="" value={withdrawAmt} onChange={setWithdrawAmt} />
        <TxButton
          onClick={() => { const v = parseEther(withdrawAmt || '0'); if (v > 0n) void run('withdraw', [id, v]) }}
          isPending={isPending} isConfirming={isConfirming} variant="ghost"
        >Withdraw</TxButton>
      </div>

      {/* Change limits — labels computed from effectiveLimits */}
      <div className="bg-white rounded-xl border border-gray-200 p-4 space-y-3">
        <p className="text-sm font-medium text-gray-800">Change limits</p>
        <div className="grid grid-cols-2 gap-3">
          <AmountInput
            label={`Per-payment cap — ${perCapLabel}`}
            value={newPerCap} onChange={setNewPerCap}
          />
          <AmountInput
            label={`Period cap — ${periodCapLabel}`}
            value={newPeriodCap} onChange={setNewPeriodCap}
          />
        </div>
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">
            Expiry — {expiryLabel}
          </label>
          <input
            type="datetime-local"
            value={newExpiry}
            onChange={e => setNewExpiry(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
          />
        </div>
        <p className="text-xs text-gray-400">{changeNote}</p>
        <TxButton
          onClick={() => {
            if (!perCapBig || !periodCapBig || newExpiryS <= nowS) { toast.error('Check limit values.'); return }
            void run('setLimits', [id, perCapBig, periodCapBig, BigInt(newExpiryS)])
          }}
          isPending={isPending} isConfirming={isConfirming} variant="ghost"
        >Update limits</TxButton>
      </div>

      {/* Pause / Unpause */}
      <div className="flex gap-3">
        <TxButton
          onClick={() => { void run(isPaused ? 'unpause' : 'pause', [id]) }}
          isPending={isPending} isConfirming={isConfirming} variant="ghost"
        >
          {isPaused ? 'Unpause' : 'Pause'}
        </TxButton>

        <TxButton
          onClick={() => setShowRevoke(true)}
          variant="danger" disabled={showRevoke}
        >
          Revoke
        </TxButton>
      </div>

      {showRevoke && (
        <div className="bg-red-50 border border-red-200 rounded-xl p-4 space-y-3">
          <p className="text-sm text-red-800">
            Revoke permanently disables this allowance and returns <strong>{fmtUsdc(allowance.balance)} USDC</strong> to you.
            This cannot be undone.
          </p>
          <div className="flex gap-2">
            <TxButton
              onClick={() => { void run('revoke', [id]) }}
              isPending={isPending} isConfirming={isConfirming} variant="danger"
            >Yes, revoke</TxButton>
            <TxButton onClick={() => setShowRevoke(false)} variant="ghost">Cancel</TxButton>
          </div>
        </div>
      )}
    </div>
  )
}

// ── Spender pay form ──────────────────────────────────────────────────────────

function SpenderPayForm({ id, allowance, budgetData, payeesData, cfg, chainId, switchChain, onDone }: {
  id: bigint; allowance: AllowanceData
  budgetData: { status: number; remainingInPeriod: bigint; maxPayment: bigint }
  payeesData: readonly [readonly `0x${string}`[], readonly bigint[]] | undefined
  cfg: ReturnType<typeof useNetwork>['cfg']; chainId: number | undefined
  switchChain: ReturnType<typeof useSwitchChain>['switchChain']; onDone: () => void
}) {
  const [payee, setPayee] = useState('')
  const [amount, setAmount] = useState('')
  const [requestId, setRequestId] = useState('')
  const [memo, setMemo] = useState('')
  const [canPayResult, setCanPayResult] = useState<{ ok: boolean; reason: number } | null>(null)

  const ref: `0x${string}` = requestId
    ? keccak256(toBytes(requestId))
    : '0x0000000000000000000000000000000000000000000000000000000000000000'

  const amtBig: bigint = (() => { try { return parseEther(amount || '0') } catch { return 0n } })()

  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (isSuccess) { onDone(); toast.success('Payment sent!') } }, [isSuccess])

  const { data: cpData } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'canPay',
    args: [id, (payee || '0x0000000000000000000000000000000000000000') as `0x${string}`, amtBig, ref],
    chainId: cfg.chain.id,
    query: { enabled: !!payee && !!amount, refetchInterval: 5000 },
  })

  useEffect(() => {
    if (cpData) setCanPayResult({ ok: cpData[0], reason: cpData[1] })
  }, [cpData])

  const nowTs = Math.floor(Date.now() / 1000)
  const activePayees = payeesData
    ? payeesData[0].filter((_, i) => Number(payeesData[1][i]) <= nowTs)
    : []

  const handlePay = async () => {
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    if (bytes(memo).length > 140) { toast.error('Memo too long.'); return }
    if (amtBig === 0n) { toast.error('Amount must be > 0.'); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    writeContract({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'pay',
      args: [id, payee as `0x${string}`, amtBig, ref, memo],
      maxFeePerGas: maxFee, maxPriorityFeePerGas: PRIORITY_FEE, chainId: cfg.chain.id,
    })
  }

  return (
    <div className="bg-white rounded-xl border border-gray-200 p-5 space-y-4">
      <h3 className="font-semibold text-gray-900">Pay</h3>
      <p className="text-xs text-gray-400">
        Max this payment: {fmtUsdc(budgetData.maxPayment)} USDC
      </p>

      {/* Payee */}
      {allowance.useAllowlist && activePayees.length > 0 ? (
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">Payee</label>
          <select
            value={payee}
            onChange={e => setPayee(e.target.value)}
            className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500"
          >
            <option value="">Select payee…</option>
            {activePayees.map(p => <option key={p} value={p}>{shortAddr(p)}</option>)}
          </select>
        </div>
      ) : (
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">Payee address</label>
          <input type="text" value={payee} onChange={e => setPayee(e.target.value)} placeholder="0x…"
            className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500" />
        </div>
      )}

      <AmountInput label="Amount" value={amount} onChange={setAmount} />

      <div className="space-y-1">
        <label className="text-sm font-medium text-gray-700">Request ID <span className="text-gray-400 font-normal">(optional, unique per allowance)</span></label>
        <input type="text" value={requestId} onChange={e => setRequestId(e.target.value)} placeholder="invoice-42"
          className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500" />
      </div>

      <div className="space-y-1">
        <label className="text-sm font-medium text-gray-700">Memo <span className="text-gray-400 font-normal">(≤ 140 bytes)</span></label>
        <input type="text" value={memo} onChange={e => setMemo(e.target.value.slice(0, 140))} placeholder="GET /v1/prices"
          className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500" />
      </div>

      {canPayResult && !canPayResult.ok && (
        <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">
          {CAN_PAY_REASONS[canPayResult.reason] ?? 'Cannot pay right now.'}
        </p>
      )}

      <TxButton
        onClick={() => { void handlePay() }}
        disabled={!!canPayResult && !canPayResult.ok}
        isPending={isPending}
        isConfirming={isConfirming}
        className="w-full"
      >
        Send payment
      </TxButton>
    </div>
  )
}

function bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s)
}

// ── History ───────────────────────────────────────────────────────────────────

function HistorySection({ id, cfg }: { id: bigint; cfg: ReturnType<typeof useNetwork>['cfg'] }) {
  const { entries, loading, error, retry } = useAllowanceHistoryLocal(id, cfg)

  if (loading) return <div className="text-xs text-gray-400">Loading history…</div>

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="font-semibold text-gray-900">History</h3>
        <button onClick={retry} className="text-xs text-red-600 hover:text-red-800">Refresh</button>
      </div>
      {error && <p className="text-xs text-yellow-700 bg-yellow-50 px-3 py-2 rounded-lg">{error} <button onClick={retry} className="underline">Retry</button></p>}
      {entries.length === 0 && !loading && <p className="text-xs text-gray-400">No events found yet.</p>}
      <div className="space-y-2">
        {entries.map((e, i) => (
          <div key={i} className="flex items-start justify-between text-xs bg-white border border-gray-200 rounded-lg px-3 py-2 gap-3">
            <span className="font-medium text-gray-700 shrink-0">{e.type}</span>
            <span className="text-gray-400 truncate flex-1">{formatEventArgs(e)}</span>
            <TxLink hash={e.transactionHash} className="shrink-0" />
          </div>
        ))}
      </div>
    </div>
  )
}

function safeStr(v: unknown): string {
  if (typeof v === 'string') return v
  return ''
}

function formatEventArgs(e: { type: string; args: Record<string, unknown> }): string {
  const a = e.args
  switch (e.type) {
    case 'Paid': return `${fmtUsdc(a.amount as bigint)} USDC → ${shortAddr(safeStr(a.payee))}`
    case 'Funded': return `+${fmtUsdc(a.amount as bigint)} USDC`
    case 'Withdrawn': return `-${fmtUsdc(a.amount as bigint)} USDC`
    case 'Revoked': return `Returned ${fmtUsdc(a.refunded as bigint)} USDC`
    case 'LimitsChanged': return `PerCap ${fmtUsdc(a.perPaymentCap as bigint)}, PeriodCap ${fmtUsdc(a.periodCap as bigint)}`
    case 'PayeeAdded': return `Added ${shortAddr(safeStr(a.payee))}`
    case 'PayeeRemoved': return `Removed ${shortAddr(safeStr(a.payee))}`
    case 'PausedSet': return a.paused ? 'Paused' : 'Unpaused'
    default: return ''
  }
}

// Inline lightweight version that avoids the hook's complex decoding
function useAllowanceHistoryLocal(id: bigint, cfg: ReturnType<typeof useNetwork>['cfg']) {
  type Entry = { type: string; blockNumber: bigint; transactionHash: `0x${string}`; args: Record<string, unknown> }
  const [entries, setEntries] = useState<Entry[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const loadHistory = useCallback(async () => {
    if (!id || id === 0n) return
    setLoading(true)
    setError(null)
    const client = createPublicClient({ chain: cfg.chain, transport: httpTransport(cfg.chain.rpcUrls.default.http[0]) })

    try {
      const head = await client.getBlockNumber()
      const idTopic = ('0x' + id.toString(16).padStart(64, '0')) as `0x${string}`
      const CHUNK = 9000n
      const allLogs: Entry[] = []

      for (let from = cfg.deploymentBlock; from <= head; from += CHUNK) {
        const to = from + CHUNK - 1n < head ? from + CHUNK - 1n : head
        try {
          const logs = await client.getLogs({ address: cfg.address, fromBlock: from, toBlock: to })
          for (const log of logs) {
            if (log.topics[1] !== idTopic) continue
            allLogs.push({
              type: 'Event',
              blockNumber: log.blockNumber ?? 0n,
              transactionHash: log.transactionHash ?? '0x',
              args: {
                payee: log.topics[2] ? '0x' + log.topics[2].slice(26) : '',
                ref: log.topics[3] ? shortBytes32(log.topics[3]) : '',
              },
            })
          }
        } catch {
          setError('Some history may be missing.')
        }
      }
      setEntries(allLogs)
    } catch (e) {
      setError('History unavailable: ' + String(e))
    } finally {
      setLoading(false)
    }
  }, [id, cfg.address, cfg.chain, cfg.deploymentBlock])

  useEffect(() => { void loadHistory() }, [loadHistory]) // eslint-disable-line react/set-state-in-effect

  return { entries, loading, error, retry: () => { void loadHistory() } }
}
