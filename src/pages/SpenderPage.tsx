import React, { useState, useEffect } from 'react'
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useSwitchChain } from 'wagmi'
import { parseEther, keccak256, toBytes } from 'viem'
import { toast } from 'sonner'
import { useNetwork } from '../hooks/useNetwork'
import { USDC_ALLOWANCE_ABI } from '../config/abi'
import { fmtUsdc, fmtCountdown, shortAddr, CAN_PAY_REASONS } from '../lib/format'
import { AddressLink } from '../components/ExplorerLink'
import { TxButton } from '../components/TxButton'
import { AmountInput } from '../components/AmountInput'
import { StatusBadge } from '../components/StatusBadge'
import { useCountdown } from '../hooks/useCountdown'

const MAX_FEE = 20_000_000_000n

export function SpenderPage() {
  const { address, isConnected, chainId } = useAccount()
  const { cfg } = useNetwork()
  const { switchChain } = useSwitchChain()

  const { data: ids } = useReadContract({
    address: cfg.address,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'idsBySpender',
    args: [address ?? '0x0000000000000000000000000000000000000000'],
    chainId: cfg.chain.id,
    query: { enabled: isConnected && !!address },
  })

  if (!isConnected) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16 text-center">
        <p className="text-gray-400 text-sm">Connect your wallet to see allowances assigned to you.</p>
      </div>
    )
  }

  return (
    <div className="max-w-2xl mx-auto px-4 py-8 space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Spender</h1>
        <p className="text-sm text-gray-500 mt-1">Allowances where {shortAddr(address!)} is the assigned spender.</p>
      </div>

      {(!ids || ids.length === 0) ? (
        <p className="text-sm text-gray-400">No allowances assigned to this address.</p>
      ) : (
        <div className="space-y-6">
          {ids.map(id => (
            <SpenderAllowanceCard key={id.toString()} id={id} cfg={cfg} chainId={chainId} switchChain={switchChain} />
          ))}
        </div>
      )}
    </div>
  )
}

function SpenderAllowanceCard({ id, cfg, chainId, switchChain }: {
  id: bigint
  cfg: ReturnType<typeof useNetwork>['cfg']
  chainId: number | undefined
  switchChain: ReturnType<typeof useSwitchChain>['switchChain']
}) {
  const [payee, setPayee] = useState('')
  const [amount, setAmount] = useState('')
  const [requestId, setRequestId] = useState('')
  const [memo, setMemo] = useState('')
  const [showForm, setShowForm] = useState(false)

  const { data: allowance } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'getAllowance',
    args: [id], chainId: cfg.chain.id,
  })
  const { data: budgetData, refetch: refetchBudget } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'budget',
    args: [id], chainId: cfg.chain.id,
    query: { refetchInterval: 15000 },
  })
  const { data: labelStr } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'labelOf',
    args: [id], chainId: cfg.chain.id,
  })
  const { data: payeesData } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'getPayees',
    args: [id], chainId: cfg.chain.id,
  })

  const activePayees = payeesData
    ? payeesData[0].filter((_, i) => Number(payeesData[1][i]) <= Math.floor(Date.now() / 1000))
    : []

  const ref: `0x${string}` = requestId
    ? keccak256(toBytes(requestId))
    : '0x0000000000000000000000000000000000000000000000000000000000000000'

  let amtBig: bigint = 0n
  try { amtBig = parseEther(amount || '0') } catch { /* */ }

  const { data: cpData } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'canPay',
    args: [id, (payee || '0x0000000000000000000000000000000000000000') as `0x${string}`, amtBig, ref],
    chainId: cfg.chain.id,
    query: { enabled: !!payee && amtBig > 0n, refetchInterval: 5000 },
  })

  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (isSuccess) { void refetchBudget(); toast.success('Payment sent!') }
  }, [isSuccess])

  const secs = useCountdown(budgetData?.periodEnd)

  if (!allowance || !budgetData) return <div className="h-24 bg-white rounded-xl border border-gray-200 animate-pulse" />

  const handlePay = () => {
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    if (amtBig === 0n) { toast.error('Amount must be > 0.'); return }
    if (!payee || !/^0x[0-9a-fA-F]{40}$/.test(payee)) { toast.error('Invalid payee address.'); return }
    writeContract({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'pay',
      args: [id, payee as `0x${string}`, amtBig, ref, memo],
      maxFeePerGas: MAX_FEE, chainId: cfg.chain.id,
    })
  }

  return (
    <div className="bg-white rounded-xl border border-gray-200 p-5 space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between gap-2">
        <div>
          <div className="flex items-center gap-2">
            <span className="text-xs text-gray-400 font-mono">#{id.toString()}</span>
            {labelStr && <span className="text-sm font-semibold text-gray-900">{labelStr}</span>}
          </div>
          <div className="text-xs text-gray-400">Owner: <AddressLink address={allowance.owner} /></div>
        </div>
        <StatusBadge status={budgetData.status} />
      </div>

      {/* Budget summary */}
      <div className="grid grid-cols-2 gap-3 bg-gray-50 rounded-lg p-3">
        <div>
          <p className="text-xs text-gray-400">You can spend</p>
          <p className="text-lg font-bold tabular-nums text-gray-900">{fmtUsdc(budgetData.remainingInPeriod)} <span className="text-sm font-normal text-gray-400">USDC</span></p>
          {budgetData.status === 1 && <p className="text-xs text-gray-400">resets in {fmtCountdown(secs)}</p>}
        </div>
        <div>
          <p className="text-xs text-gray-400">Max single payment</p>
          <p className="text-lg font-bold tabular-nums text-gray-900">{fmtUsdc(budgetData.maxPayment)} <span className="text-sm font-normal text-gray-400">USDC</span></p>
        </div>
      </div>

      {/* Allowed payees */}
      {allowance.useAllowlist && activePayees.length > 0 && (
        <div>
          <p className="text-xs text-gray-500 mb-1">Allowed payees</p>
          <div className="flex flex-wrap gap-2">
            {activePayees.map(p => (
              <button key={p} onClick={() => setPayee(p)}
                className={`text-xs font-mono px-2 py-1 rounded border transition-colors ${payee === p ? 'bg-red-600 text-white border-red-600' : 'border-gray-300 text-gray-600 hover:border-red-400'}`}>
                {shortAddr(p)}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Pay form toggle */}
      {budgetData.status === 1 && (
        <>
          <button onClick={() => setShowForm(v => !v)}
            className="text-sm text-red-600 font-medium hover:text-red-800">
            {showForm ? 'Hide pay form' : 'Pay from this allowance →'}
          </button>

          {showForm && (
            <div className="space-y-3 pt-2 border-t border-gray-100">
              {!allowance.useAllowlist || activePayees.length === 0 ? (
                <div className="space-y-1">
                  <label className="text-sm font-medium text-gray-700">Payee</label>
                  <input type="text" value={payee} onChange={e => setPayee(e.target.value)} placeholder="0x…"
                    className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500" />
                </div>
              ) : (
                <p className="text-xs text-gray-400">Payee selected above</p>
              )}
              <AmountInput label="Amount" value={amount} onChange={setAmount} />
              <div className="space-y-1">
                <label className="text-sm font-medium text-gray-700">Request ID <span className="text-gray-400 font-normal">(optional)</span></label>
                <input type="text" value={requestId} onChange={e => setRequestId(e.target.value)} placeholder="invoice-42"
                  className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500" />
              </div>
              <div className="space-y-1">
                <label className="text-sm font-medium text-gray-700">Memo</label>
                <input type="text" value={memo} onChange={e => setMemo(e.target.value.slice(0, 140))} placeholder="GET /v1/prices"
                  className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500" />
              </div>

              {cpData && !cpData[0] && (
                <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">
                  {CAN_PAY_REASONS[cpData[1]] ?? 'Cannot pay right now.'}
                </p>
              )}

              <TxButton
                onClick={handlePay}
                disabled={cpData !== undefined && !cpData[0]}
                isPending={isPending} isConfirming={isConfirming}
                className="w-full"
              >
                Send payment
              </TxButton>
            </div>
          )}
        </>
      )}
    </div>
  )
}
