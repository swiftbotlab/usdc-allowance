/**
 * Guided demo: "A research agent pays a data API"
 * Five steps: connect owner → create agent key → fund allowance → run 4 queries → revoke.
 * Without a wallet / before step 3 also shows a read-only event replay panel.
 */
import React, { useState, useEffect, useRef, useCallback } from 'react'
import {
  useAccount,
  useWriteContract,
  useWaitForTransactionReceipt,
  useSwitchChain,
  useReadContract,
  usePublicClient,
} from 'wagmi'
import {
  parseEther,
  keccak256,
  toBytes,
  decodeEventLog,
  formatEther,
} from 'viem'
import { toast } from 'sonner'
import { Copy, ExternalLink, RefreshCw, Trash2 } from 'lucide-react'
import { useNetwork } from '../hooks/useNetwork'
import { USDC_ALLOWANCE_ABI } from '../config/abi'
import { fmtUsdc, fmtCountdown } from '../lib/format'
import { getDynamicMaxFee, PRIORITY_FEE } from '../lib/gas'
import { TxButton } from '../components/TxButton'
import { TxLink, AddressLink } from '../components/ExplorerLink'
import { useCountdown } from '../hooks/useCountdown'
import {
  loadOrCreateAgentKey,
  forgetAgentKey,
  saveDemoId,
  loadDemoId,
  type AgentKey,
} from '../demo/agentKey'
import { agentPay, agentPayForceOnchain } from '../demo/agentPay'
import { fetchReplayEvents, type ReplayEntry } from '../demo/replayEvents'
import { QUERIES, NET_AMOUNTS, type LogEntry, type Speaker } from '../demo/types'

// ── helpers ───────────────────────────────────────────────────────────────────

let _logId = 0
function mkLog(speaker: Speaker, text: string, extra?: Partial<LogEntry>): LogEntry {
  return { id: _logId++, ts: Date.now(), speaker, text, ...extra }
}

function SpeakerChip({ s }: { s: Speaker }) {
  const cls: Record<Speaker, string> = {
    Agent:   'bg-blue-100 text-blue-700',
    Contract:'bg-red-100 text-red-700',
    DataAPI: 'bg-green-100 text-green-700',
    System:  'bg-gray-100 text-gray-500',
  }
  return <span className={`inline-block text-[10px] font-semibold px-1.5 py-0.5 rounded shrink-0 ${cls[s]}`}>{s}</span>
}

function LogPane({ entries, explorerBase }: { entries: LogEntry[]; explorerBase: string }) {
  const bottomRef = useRef<HTMLDivElement>(null)
  useEffect(() => { bottomRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [entries.length])

  return (
    <div className="bg-gray-950 rounded-xl p-4 h-72 overflow-y-auto space-y-2 font-mono text-xs">
      {entries.length === 0 && <p className="text-gray-600">Waiting for agent…</p>}
      {entries.map(e => (
        <div key={e.id} className={`flex gap-2 ${e.isError ? 'text-red-400' : 'text-gray-300'}`}>
          <SpeakerChip s={e.speaker} />
          <span className="flex-1 leading-relaxed break-all">{e.text}</span>
          {e.txHash && (
            <a
              href={`${explorerBase}/tx/${e.txHash}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-gray-500 hover:text-gray-300"
            >
              <ExternalLink className="w-3 h-3" />
            </a>
          )}
        </div>
      ))}
      <div ref={bottomRef} />
    </div>
  )
}

// ── main component ────────────────────────────────────────────────────────────

export function DemoPage() {
  const { network, cfg } = useNetwork()
  const { address, isConnected, chainId } = useAccount()
  const { switchChain } = useSwitchChain()
  const pub = usePublicClient()

  const amounts = NET_AMOUNTS[network]

  // Agent key
  const [agentKey, setAgentKey] = useState<AgentKey | null>(null)
  const [agentBalance, setAgentBalance] = useState<bigint | null>(null)

  // Demo allowance id (persisted to localStorage)
  // eslint-disable-next-line react/set-state-in-effect
  const [demoId, setDemoId] = useState<bigint | null>(null)

  // Payee — defaults to owner address once known
  const [payee, setPayee] = useState('')
  // eslint-disable-next-line react/set-state-in-effect
  useEffect(() => { if (address && !payee) setPayee(address) }, [address, payee])

  // Log entries for the live panel
  const [logs, setLogs] = useState<LogEntry[]>([])
  const addLog = useCallback((l: LogEntry) => setLogs(prev => [...prev, l]), [])

  // Running state
  const [isRunning, setIsRunning] = useState(false)
  const [queryIdx, setQueryIdx] = useState(0)           // 0-3 (next query to send)
  const [overCapSent, setOverCapSent] = useState(false)  // "send anyway" already clicked
  const [canRetry, setCanRetry] = useState(false)        // countdown reached 0

  // Replay panel
  const [replayEntries, setReplayEntries] = useState<ReplayEntry[]>([])
  const [replayLoading, setReplayLoading] = useState(false)

  // Step 3 tx (createAllowance + gas drop — two sequential writes)
  const { writeContract, data: fundHash, isPending: fundPending, reset: resetFund } = useWriteContract()
  const { isLoading: fundConfirming, isSuccess: fundSuccess } = useWaitForTransactionReceipt({ hash: fundHash })

  // Step 5 tx (revoke)
  const { writeContract: revokeWc, data: revokeHash, isPending: revokePending } = useWriteContract()
  const { isLoading: revokeConfirming, isSuccess: revokeSuccess } = useWaitForTransactionReceipt({ hash: revokeHash })

  // Reset network-dependent state when network changes (also runs on first mount)
  useEffect(() => {
    // eslint-disable-next-line react/set-state-in-effect
    setAgentKey(null)
    setAgentBalance(null)
    setDemoId(loadDemoId(network))
    setLogs([])
    setQueryIdx(0)
    setOverCapSent(false)
    setCanRetry(false)
    setPayee('')
  }, [network])

  // ── budget for countdown ─────────────────────────────────────────────────

  const { data: budgetData, refetch: refetchBudget } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'budget',
    args: [demoId ?? 1n], chainId: cfg.chain.id,
    query: { enabled: !!demoId, refetchInterval: 10000 },
  })

  const { data: postRevokeAllowance } = useReadContract({
    address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'getAllowance',
    args: [demoId ?? 1n], chainId: cfg.chain.id,
    query: { enabled: revokeSuccess && !!demoId },
  })

  const periodEndSecs = budgetData ? Number(budgetData.periodEnd) : 0
  // eslint-disable-next-line react/purity
  const nowSecs = Math.floor(Date.now() / 1000)
  const secsUntilReset = Math.max(0, periodEndSecs - nowSecs)
  const countdownSecs = useCountdown(BigInt(periodEndSecs))

  // Enable retry when countdown hits 0
  useEffect(() => {
    if (countdownSecs === 0 && queryIdx === 3 && !canRetry) {
      // eslint-disable-next-line react/set-state-in-effect
      setCanRetry(true)
      addLog(mkLog('System', 'Period reset. "Try again" is now available.'))
    }
  }, [countdownSecs, queryIdx, canRetry, addLog])

  // ── step 2: load / create agent key ──────────────────────────────────────

  const handleStep2 = () => {
    const key = loadOrCreateAgentKey(network)
    setAgentKey(key)
    fetchAgentBalance(key)
  }

  const fetchAgentBalance = useCallback((key: AgentKey) => {
    if (!pub) return
    void pub.getBalance({ address: key.address }).then(b => setAgentBalance(b)).catch(() => {})
  }, [pub])

  useEffect(() => {
    if (agentKey) fetchAgentBalance(agentKey)
  }, [agentKey, fetchAgentBalance]) // eslint-disable-line react/set-state-in-effect

  const handleForget = () => {
    forgetAgentKey(network)
    setAgentKey(null)
    setAgentBalance(null)
    setDemoId(null)
    setLogs([])
    setQueryIdx(0)
    setOverCapSent(false)
    setCanRetry(false)
  }

  // ── step 3: fund allowance (createAllowance + gas drop, sequential) ──────

  const [step3Phase, setStep3Phase] = useState<'idle' | 'creating' | 'dropping'>('idle')
  const [createHash, setCreateHash] = useState<`0x${string}` | undefined>(undefined)
  const { isSuccess: createSuccess, data: createReceipt } = useWaitForTransactionReceipt({ hash: createHash })

  // After createAllowance confirmed → extract id → do gas drop
  // eslint-disable-next-line react/set-state-in-effect
  useEffect(() => {
    if (!createSuccess || !createReceipt || step3Phase !== 'creating') return
    let newId: bigint | null = null
    for (const log of createReceipt.logs) {
      try {
        const decoded = decodeEventLog({ abi: USDC_ALLOWANCE_ABI, data: log.data, topics: log.topics })
        if (decoded.eventName === 'AllowanceCreated') {
          newId = (decoded.args as { id: bigint }).id
          break
        }
      } catch { /* skip */ }
    }
    if (!newId) {
      toast.error('Could not read allowance ID from tx.')
      // eslint-disable-next-line react/set-state-in-effect
      setStep3Phase('idle')
      return
    }
    // eslint-disable-next-line react/set-state-in-effect
    setDemoId(newId)
    saveDemoId(network, newId)
    toast.success(`Allowance #${newId.toString()} created!`)

    // Now do the gas drop (plain native transfer to agent)
    void (async () => {
      if (!agentKey) return
      try {
        setStep3Phase('dropping')
        const maxFee = await getDynamicMaxFee(cfg.chain)
        writeContract({
          address: agentKey.address,  // send-to
          abi: [],
          functionName: undefined as never,
          args: [],
          value: parseEther(amounts.gasDrop),
          maxFeePerGas: maxFee,
          maxPriorityFeePerGas: PRIORITY_FEE,
          chainId: cfg.chain.id,
        })
      } catch {
        toast.error('Gas drop failed.')
        setStep3Phase('idle')
      }
    })()
  }, [createSuccess, createReceipt, step3Phase, network, agentKey, amounts.gasDrop, cfg.chain, writeContract]) // eslint-disable-line react/set-state-in-effect

  // After gas drop confirmed
  useEffect(() => {
    if (fundSuccess && step3Phase === 'dropping') {
      toast.success(`Sent ${amounts.gasDrop} USDC to agent for gas.`)
      // eslint-disable-next-line react/set-state-in-effect
      setStep3Phase('idle')
      if (agentKey) fetchAgentBalance(agentKey)
    }
  }, [fundSuccess, step3Phase, amounts.gasDrop, agentKey, fetchAgentBalance])

  const handleStep3 = async () => {
    if (!isConnected || !address) { toast.error('Connect your wallet first.'); return }
    if (!agentKey) { toast.error('Generate an agent key first (step 2).'); return }
    if (!payee || !/^0x[0-9a-fA-F]{40}$/.test(payee)) { toast.error('Enter a valid payee address.'); return }
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }

    const nowS = Math.floor(Date.now() / 1000)
    const maxFee = await getDynamicMaxFee(cfg.chain)

    resetFund()
    setStep3Phase('creating')

    try {
      const hash = await new Promise<`0x${string}`>((resolve, reject) => {
        writeContract(
          {
            address: cfg.address,
            abi: USDC_ALLOWANCE_ABI,
            functionName: 'createAllowance',
            args: [
              agentKey.address,
              {
                perPaymentCap: parseEther(amounts.perPaymentCap),
                periodCap: parseEther(amounts.periodCap),
                periodLength: 300n,
                periodAnchor: BigInt(nowS),
                expiresAt: BigInt(nowS + 7 * 86400),
                loosenDelay: 120,
                useAllowlist: true,
              },
              [payee as `0x${string}`],
              'research-agent demo',
            ],
            value: parseEther(amounts.fund),
            maxFeePerGas: maxFee,
            maxPriorityFeePerGas: PRIORITY_FEE,
            chainId: cfg.chain.id,
          },
          {
            onSuccess: (h) => resolve(h),
            onError: (e) => reject(e instanceof Error ? e : new Error('Transaction error')),
          }
        )
      })
      setCreateHash(hash)
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e)
      if (!msg.includes('rejected') && !msg.includes('denied')) toast.error(msg.slice(0, 120))
      setStep3Phase('idle')
    }
  }

  // ── step 4: run agent ─────────────────────────────────────────────────────

  const handleRunAgent = async () => {
    if (!demoId || !agentKey) return
    setIsRunning(true)
    setLogs([])

    for (let i = 0; i < QUERIES.length; i++) {
      const q = QUERIES[i]
      const requestId = `demo-${network}-${demoId.toString()}-q${i}-${Date.now()}`
      const ref = keccak256(toBytes(requestId))
      const memo = `GET /v1/${q.slug}`
      const isOverCap = i === 3 // 4th query over period cap

      addLog(mkLog('Agent', `canPay(id=${demoId}, payee=${payee.slice(0, 8)}…, amount=${amounts.price}, ref=${ref.slice(0, 10)}…)`))

      // canPay via publicClient
      let canPayOk = false
      let canPayReason = 0
      try {
        if (!pub) throw new Error('no client')
        const result = await pub.readContract({
          address: cfg.address,
          abi: USDC_ALLOWANCE_ABI,
          functionName: 'canPay',
          args: [demoId, payee as `0x${string}`, parseEther(amounts.price), ref],
        }) as [boolean, number]
        canPayOk = result[0]
        canPayReason = result[1]
      } catch {
        canPayOk = false
        canPayReason = 0
      }

      if (!canPayOk) {
        // Build decoded reason sentence
        const remainingStr = budgetData
          ? fmtUsdc(budgetData.remainingInPeriod)
          : '0.00'
        const resetIn = secsUntilReset > 0 ? fmtCountdown(secsUntilReset) : '0:00'
        const reasonMsg = canPayReason === 9
          ? `ExceedsPeriodCap. Asked ${amounts.price}, ${remainingStr} left this period. Resets in ${resetIn}.`
          : `Reason code ${canPayReason}`
        addLog(mkLog('Contract', `Rejected: ${reasonMsg}`, { isError: true }))

        // Only the 4th query gets the "Send anyway" flow; stop for earlier failures
        if (i < 3 || canPayReason !== 9) { setIsRunning(false); return }

        // 4th query: present the rejected state; user can click "Send anyway"
        setQueryIdx(3)
        setIsRunning(false)
        return
      }

      addLog(mkLog('Contract', 'canPay → OK'))
      addLog(mkLog('Agent', `pay(id=${demoId}, payee=${payee.slice(0, 8)}…, amount=${amounts.price}${isOverCap ? ' [over cap]' : ''}, memo="${memo}")`))

      try {
        const result = await agentPay({
          privateKey: agentKey.privateKey,
          chain: cfg.chain,
          contractAddress: cfg.address,
          id: demoId,
          payee: payee as `0x${string}`,
          amount: amounts.price,
          requestId,
          memo,
        })

        if (!result.success) {
          addLog(mkLog('Contract', 'Transaction reverted on-chain.', { isError: true, txHash: result.hash, explorerBase: cfg.explorerBase }))
          setIsRunning(false)
          return
        }

        addLog(mkLog('Contract', `Paid log verified ✓  tx ${result.hash.slice(0, 10)}…`, { txHash: result.hash, explorerBase: cfg.explorerBase }))
        addLog(mkLog('DataAPI', result.paidLogFound ? q.sampleData : '[receipt check failed — no data]'))

        void refetchBudget()
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e)
        addLog(mkLog('Agent', `Error: ${msg.slice(0, 120)}`, { isError: true }))
        setIsRunning(false)
        return
      }

      setQueryIdx(i + 1)

      // Small pause between queries
      await new Promise(r => setTimeout(r, 600))
    }

    setIsRunning(false)
  }

  // ── "Send anyway" (over-cap query, force onchain) ─────────────────────────

  const handleSendAnyway = async () => {
    if (!demoId || !agentKey) return
    setOverCapSent(true)
    const q = QUERIES[3]
    const requestId = `demo-${network}-${demoId.toString()}-q3-force-${Date.now()}`
    const memo = `GET /v1/${q.slug}`

    addLog(mkLog('Agent', `Sending anyway with gas=150000… (expected revert)`))
    try {
      const result = await agentPayForceOnchain({
        privateKey: agentKey.privateKey,
        chain: cfg.chain,
        contractAddress: cfg.address,
        id: demoId,
        payee: payee as `0x${string}`,
        amount: amounts.price,
        requestId,
        memo,
      })
      if (!result.success) {
        addLog(mkLog('Contract', `Failed on-chain: ExceedsPeriodCap`, { isError: true, txHash: result.hash, explorerBase: cfg.explorerBase }))
      } else {
        addLog(mkLog('Contract', `Unexpectedly succeeded: ${result.hash.slice(0, 10)}…`, { txHash: result.hash, explorerBase: cfg.explorerBase }))
      }
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e)
      addLog(mkLog('Agent', `Error: ${msg.slice(0, 120)}`, { isError: true }))
    }
  }

  // ── "Try again" (after period reset) ─────────────────────────────────────

  const handleRetry = async () => {
    if (!demoId || !agentKey) return
    setIsRunning(true)
    const q = QUERIES[3]
    const requestId = `demo-${network}-${demoId.toString()}-q3-retry-${Date.now()}`
    const ref = keccak256(toBytes(requestId))
    const memo = `GET /v1/${q.slug}`

    addLog(mkLog('Agent', `canPay — new period check`))
    let canPayOk = false
    try {
      if (!pub) throw new Error('no client')
      const result = await pub.readContract({
        address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'canPay',
        args: [demoId, payee as `0x${string}`, parseEther(amounts.price), ref],
      }) as [boolean, number]
      canPayOk = result[0]
    } catch { canPayOk = false }

    if (!canPayOk) {
      addLog(mkLog('Contract', 'Still rejected. Wait a moment longer.', { isError: true }))
      setIsRunning(false)
      return
    }
    addLog(mkLog('Contract', 'canPay → OK'))
    addLog(mkLog('Agent', `pay(id=${demoId}, q=4 "${q.label}", amount=${amounts.price})`))

    try {
      const result = await agentPay({
        privateKey: agentKey.privateKey, chain: cfg.chain,
        contractAddress: cfg.address, id: demoId,
        payee: payee as `0x${string}`, amount: amounts.price,
        requestId, memo,
      })
      if (result.success) {
        addLog(mkLog('Contract', `Paid ✓`, { txHash: result.hash, explorerBase: cfg.explorerBase }))
        addLog(mkLog('DataAPI', result.paidLogFound ? q.sampleData : '[receipt check failed]'))
        setQueryIdx(4)
        void refetchBudget()
      } else {
        addLog(mkLog('Contract', 'Reverted.', { isError: true, txHash: result.hash }))
      }
    } catch (e: unknown) {
      addLog(mkLog('Agent', `Error: ${String(e).slice(0, 120)}`, { isError: true }))
    }
    setIsRunning(false)
  }

  // ── step 5: revoke ────────────────────────────────────────────────────────

  const handleRevoke = async () => {
    if (!demoId || !isConnected) return
    if (chainId !== cfg.chain.id) { switchChain({ chainId: cfg.chain.id }); return }
    const maxFee = await getDynamicMaxFee(cfg.chain)
    revokeWc({
      address: cfg.address, abi: USDC_ALLOWANCE_ABI, functionName: 'revoke',
      args: [demoId], maxFeePerGas: maxFee, maxPriorityFeePerGas: PRIORITY_FEE, chainId: cfg.chain.id,
    })
  }

  // eslint-disable-next-line react/set-state-in-effect
  useEffect(() => {
    if (revokeSuccess) { toast.success('Allowance revoked.'); void refetchBudget() }
  }, [revokeSuccess, refetchBudget])

  // ── read-only replay ──────────────────────────────────────────────────────

  const loadReplay = useCallback(async (id: bigint) => {
    setReplayLoading(true)
    try {
      const entries = await fetchReplayEvents(id, cfg.chain, cfg.address, cfg.deploymentBlock)
      setReplayEntries(entries)
    } catch { setReplayEntries([]) }
    finally { setReplayLoading(false) }
  }, [cfg.address, cfg.chain, cfg.deploymentBlock])

  // Auto-load replay when there is a demo id and no wallet or demo not yet started
  const replayId: bigint | null = demoId ?? (cfg.demoAllowanceId > 0n ? cfg.demoAllowanceId : null)
  const showReplay = (!isConnected || queryIdx === 0) && replayId !== null
  useEffect(() => {
    // eslint-disable-next-line react/set-state-in-effect
    if (showReplay && replayId) void loadReplay(replayId)
  }, [showReplay, replayId, loadReplay])

  // ── derived state ─────────────────────────────────────────────────────────

  const step2Done = !!agentKey
  const step3Done = !!demoId
  const step4Done = queryIdx >= 4
  const step3Busy = step3Phase !== 'idle' || fundPending || fundConfirming
  const q3Rejected = queryIdx === 3 && !isRunning
  const postRevoke = revokeSuccess && !!postRevokeAllowance

  // ── render ────────────────────────────────────────────────────────────────

  return (
    <div className="max-w-2xl mx-auto px-4 py-8 space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Demo: A research agent pays a data API</h1>
        <p className="text-sm text-gray-500 mt-1">
          Walk through the full lifecycle — key generation, allowance creation, live payments, cap enforcement, and revoke.
        </p>
      </div>

      {/* ── Step 1: connect wallet ─────────────────────────────────────── */}
      <StepCard num={1} title="Connect the owner wallet" done={isConnected}>
        {isConnected
          ? <p className="text-xs text-gray-500">Connected as <AddressLink address={address!} /></p>
          : <p className="text-sm text-gray-500">Use the Connect button in the top right.</p>}
      </StepCard>

      {/* ── Step 2: create agent key ───────────────────────────────────── */}
      <StepCard num={2} title="Create agent key" done={step2Done}>
        {!step2Done ? (
          <div className="space-y-3">
            <p className="text-xs text-gray-500">
              A fresh private key is generated in the browser and stored in localStorage only.
              The allowance is what limits it — the key itself has no other permissions.
            </p>
            <button
              onClick={handleStep2}
              disabled={!isConnected}
              className="px-4 py-2 bg-red-600 text-white text-sm font-medium rounded-lg hover:bg-red-700 disabled:opacity-40 transition-colors"
            >
              Generate agent key
            </button>
          </div>
        ) : (
          <div className="space-y-2">
            <div className="flex items-center gap-2">
              <p className="text-xs text-gray-500 font-mono break-all">{agentKey.address}</p>
              <button onClick={() => void navigator.clipboard.writeText(agentKey.address)}
                className="p-1 text-gray-400 hover:text-gray-700 shrink-0">
                <Copy className="w-3.5 h-3.5" />
              </button>
              <a href={`${cfg.explorerBase}/address/${agentKey.address}`}
                target="_blank" rel="noopener noreferrer" className="p-1 text-gray-400 hover:text-gray-700 shrink-0">
                <ExternalLink className="w-3.5 h-3.5" />
              </a>
            </div>
            {agentBalance !== null && (
              <p className="text-xs text-gray-400">
                Balance: {formatEther(agentBalance).slice(0, 8)} USDC (native)
                <button onClick={() => fetchAgentBalance(agentKey)} className="ml-2 text-red-600 hover:text-red-800">
                  <RefreshCw className="w-3 h-3 inline" />
                </button>
              </p>
            )}
            <p className="text-xs text-yellow-700 bg-yellow-50 px-2 py-1 rounded">
              Hot key for this demo only: the allowance is what limits it.
            </p>
            <button onClick={handleForget} className="flex items-center gap-1 text-xs text-gray-400 hover:text-red-600 mt-1">
              <Trash2 className="w-3 h-3" /> Forget key
            </button>
          </div>
        )}
      </StepCard>

      {/* ── Step 3: fund allowance ─────────────────────────────────────── */}
      <StepCard num={3} title="Fund the agent's allowance" done={step3Done}>
        {!step3Done ? (
          <div className="space-y-3">
            <p className="text-xs text-gray-500">
              Two transactions: create a 5-minute demo allowance (spender = agent, fund {amounts.fund} USDC,
              payee allowlist with the address below) then send {amounts.gasDrop} USDC to the agent for gas.
            </p>
            <div className="space-y-1">
              <label className="text-xs font-medium text-gray-700">Payee (defaults to your own address)</label>
              <input
                type="text"
                value={payee}
                onChange={e => setPayee(e.target.value)}
                placeholder="0x…"
                className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500"
              />
              <p className="text-xs text-gray-400">
                The demo will pay {amounts.price} USDC × 3 queries to this address (≈ {amounts.fund} total funded, period cap {amounts.periodCap}).
              </p>
            </div>
            <TxButton
              onClick={() => { void handleStep3() }}
              isPending={step3Busy}
              isConfirming={step3Busy}
              disabled={!step2Done || !isConnected}
              className="w-full"
            >
              {step3Phase === 'creating'
                ? 'Creating allowance…'
                : step3Phase === 'dropping'
                  ? 'Sending gas…'
                  : `Create allowance + send gas (${amounts.fund} USDC + ${amounts.gasDrop} USDC)`}
            </TxButton>
            {fundHash && <TxLink hash={fundHash} label="Tx" className="text-xs" />}
          </div>
        ) : (
          <div className="space-y-2">
            <p className="text-xs text-gray-500">
              Allowance <strong>#{demoId.toString()}</strong> funded with {amounts.fund} USDC.
              Period cap {amounts.periodCap} USDC / 5 min. Payee: {payee.slice(0, 8)}…
            </p>
            {budgetData && (
              <p className="text-xs tabular-nums text-gray-500">
                Remaining this period: {fmtUsdc(budgetData.remainingInPeriod)} USDC &nbsp;·&nbsp;
                Period ends in {fmtCountdown(countdownSecs)}
              </p>
            )}
          </div>
        )}
      </StepCard>

      {/* ── Step 4: run agent ──────────────────────────────────────────── */}
      <StepCard num={4} title="Run agent — 4 queries" done={step4Done && !q3Rejected}>
        <p className="text-xs text-gray-500 mb-3">
          The agent calls canPay(), then pay() for each query. The 4th query ({QUERIES[3].label}) exceeds the
          period cap ({amounts.periodCap} USDC). You can then see the rejected transaction on-chain or wait for the period to reset.
        </p>

        {/* Query progress pills */}
        <div className="flex gap-2 mb-3">
          {QUERIES.map((q, i) => {
            const done = queryIdx > i && !(i === 3 && q3Rejected)
            const active = queryIdx === i && isRunning
            const failed = i === 3 && q3Rejected
            return (
              <span key={i} className={`text-xs px-2 py-1 rounded-full border ${
                done ? 'bg-green-100 text-green-700 border-green-200'
                  : failed ? 'bg-red-100 text-red-700 border-red-200'
                    : active ? 'bg-blue-100 text-blue-700 border-blue-200 animate-pulse'
                      : 'bg-gray-50 text-gray-400 border-gray-200'
              }`}>{q.label}</span>
            )
          })}
        </div>

        <LogPane entries={logs} explorerBase={cfg.explorerBase} />

        {/* Rejected cap message */}
        {q3Rejected && budgetData && (
          <div className="mt-3 bg-red-50 border border-red-200 rounded-xl p-4 space-y-3">
            <p className="text-sm font-medium text-red-800">
              Rejected by the contract: ExceedsPeriodCap.
              Asked {amounts.price}, {fmtUsdc(budgetData.remainingInPeriod)} left this period.
              Resets in {fmtCountdown(countdownSecs)}.
            </p>
            <div className="flex gap-2">
              {!overCapSent && (
                <button
                  onClick={() => { void handleSendAnyway() }}
                  className="px-3 py-1.5 bg-red-600 text-white text-xs font-medium rounded-lg hover:bg-red-700"
                >
                  Send anyway (will fail on-chain)
                </button>
              )}
              <button
                onClick={() => { void handleRetry() }}
                disabled={!canRetry || isRunning}
                className="px-3 py-1.5 bg-gray-100 text-gray-700 text-xs font-medium rounded-lg hover:bg-gray-200 disabled:opacity-40"
              >
                Try again after reset {canRetry ? '' : `(in ${fmtCountdown(countdownSecs)})`}
              </button>
            </div>
          </div>
        )}

        {!step4Done && !q3Rejected && (
          <button
            onClick={() => { void handleRunAgent() }}
            disabled={!step3Done || isRunning || !agentKey}
            className="mt-3 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 disabled:opacity-40"
          >
            {isRunning ? 'Running…' : queryIdx === 0 ? 'Run agent' : 'Resume'}
          </button>
        )}
      </StepCard>

      {/* ── Step 5: revoke ────────────────────────────────────────────── */}
      <StepCard num={5} title="Revoke" done={revokeSuccess}>
        {!revokeSuccess ? (
          <div className="space-y-3">
            <p className="text-xs text-gray-500">
              Revoke permanently disables the allowance and returns the remaining balance to you.
            </p>
            <TxButton
              onClick={() => { void handleRevoke() }}
              isPending={revokePending}
              isConfirming={revokeConfirming}
              disabled={!step3Done || !isConnected}
              variant="danger"
            >Revoke</TxButton>
            {revokeHash && <TxLink hash={revokeHash} label="Tx" className="text-xs" />}
          </div>
        ) : postRevoke ? (
          <div className="space-y-1">
            <p className="text-sm font-medium text-gray-800">Done!</p>
            <p className="text-xs text-gray-500 tabular-nums">
              Funded: {fmtUsdc(postRevokeAllowance.totalFunded)} USDC &nbsp;·&nbsp;
              Paid: {fmtUsdc(postRevokeAllowance.totalPaid)} USDC &nbsp;·&nbsp;
              Returned: {fmtUsdc(postRevokeAllowance.totalRefunded)} USDC
            </p>
          </div>
        ) : (
          <p className="text-xs text-gray-400">Revoked. Loading final stats…</p>
        )}
      </StepCard>

      {/* ── Read-only replay ──────────────────────────────────────────── */}
      {showReplay && replayId !== null && (
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-gray-800">
              Event replay — allowance #{replayId.toString()}
              {network === 'mainnet' && replayId === 1n
                ? ' (scripted mainnet run: 3 paid, cap hit, raised, 4th paid next period, revoked)'
                : ''}
            </h3>
            <button onClick={() => { void loadReplay(replayId) }}
              className="text-xs text-red-600 hover:text-red-800 flex items-center gap-1">
              <RefreshCw className="w-3 h-3" /> Refresh
            </button>
          </div>
          {replayLoading && <p className="text-xs text-gray-400">Loading…</p>}
          {!replayLoading && replayEntries.length === 0 && <p className="text-xs text-gray-400">No events found yet.</p>}
          <div className="space-y-1.5">
            {replayEntries.map((e, i) => (
              <div key={i}
                className="flex items-start gap-3 text-xs bg-white border border-gray-200 rounded-lg px-3 py-2">
                <span className={`shrink-0 font-medium ${e.eventName === 'Paid' ? 'text-green-700' : e.eventName === 'Revoked' ? 'text-red-700' : 'text-gray-700'}`}>
                  {e.eventName}
                </span>
                <span className="text-gray-500 flex-1 break-all">{e.summary}</span>
                <a href={`${cfg.explorerBase}/tx/${e.txHash}`} target="_blank" rel="noopener noreferrer"
                  className="shrink-0 text-gray-400 hover:text-gray-700">
                  <ExternalLink className="w-3 h-3" />
                </a>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

// ── StepCard ──────────────────────────────────────────────────────────────────

function StepCard({ num, title, done, children }: {
  num: number; title: string; done: boolean; children: React.ReactNode
}) {
  return (
    <div className={`rounded-xl border p-5 space-y-3 transition-colors ${done ? 'border-green-200 bg-green-50' : 'border-gray-200 bg-white'}`}>
      <div className="flex items-center gap-3">
        <span className={`w-7 h-7 rounded-full flex items-center justify-center text-sm font-bold shrink-0 ${
          done ? 'bg-green-500 text-white' : 'bg-gray-100 text-gray-500'
        }`}>{done ? '✓' : num}</span>
        <h3 className="font-semibold text-gray-900">{title}</h3>
      </div>
      <div>{children}</div>
    </div>
  )
}
