import React, { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useSwitchChain } from 'wagmi'
import { parseEther, decodeEventLog } from 'viem'
import { getDynamicMaxFee, PRIORITY_FEE } from '../lib/gas'
import { toast } from 'sonner'
import { Plus, Trash2, ChevronDown, ChevronUp } from 'lucide-react'
import { useNetwork } from '../hooks/useNetwork'
import { USDC_ALLOWANCE_ABI } from '../config/abi'
import { validateRules, decodeContractError } from '../lib/errors'
import { AmountInput } from '../components/AmountInput'
import { TxButton } from '../components/TxButton'

const PERIOD_OPTIONS = [
  { label: '5 minutes', value: 300 },
  { label: '1 hour', value: 3600 },
  { label: '1 day (UTC-aligned)', value: 86400 },
  { label: '1 week', value: 7 * 86400 },
  { label: 'Custom (seconds)', value: -1 },
]

const DELAY_OPTIONS = [
  { label: 'None (tighten only)', value: 0 },
  { label: '2 minutes', value: 120 },
  { label: '1 hour', value: 3600 },
  { label: '24 hours', value: 86400 },
]

interface FormState {
  spender: string
  label: string
  perPaymentCap: string
  periodCap: string
  periodLength: number
  customPeriod: string
  utcAligned: boolean
  expiresAt: string
  loosenDelay: number
  useAllowlist: boolean
  payees: string[]
  funding: string
}

const defaultExpiry = () => {
  const d = new Date(Date.now() + 30 * 24 * 3600 * 1000)
  d.setSeconds(0, 0)
  return d.toISOString().slice(0, 16)
}

const PRESETS = {
  agent: {
    label: 'Agent daily budget',
    form: {
      perPaymentCap: '1',
      periodCap: '5',
      periodLength: 86400,
      utcAligned: true,
      loosenDelay: 3600,
      useAllowlist: true,
    },
  },
  demo: {
    label: '5-minute demo',
    form: {
      perPaymentCap: '0.10',
      periodCap: '0.15',
      periodLength: 300,
      utcAligned: false,
      loosenDelay: 120,
      useAllowlist: true,
    },
  },
}

export function NewAllowancePage() {
  const { address, isConnected, chainId } = useAccount()
  const { network, cfg } = useNetwork()
  const { switchChain } = useSwitchChain()
  const navigate = useNavigate()

  const [form, setForm] = useState<FormState>({
    spender: '',
    label: '',
    perPaymentCap: '1',
    periodCap: '5',
    periodLength: 86400,
    customPeriod: '',
    utcAligned: true,
    expiresAt: defaultExpiry(),
    loosenDelay: 0,
    useAllowlist: false,
    payees: [],
    funding: '',
  })
  const [validationError, setValidationError] = useState<string | null>(null)
  const [showAdvanced, setShowAdvanced] = useState(false)

  const set = (k: keyof FormState, v: FormState[typeof k]) =>
    setForm(f => ({ ...f, [k]: v }))

  const effectivePeriod = form.periodLength === -1
    ? (parseInt(form.customPeriod) || 0)
    : form.periodLength

  const { writeContract, data: hash, isPending, error: writeError, reset } = useWriteContract()
  const { isLoading: isConfirming, isSuccess, data: receipt } = useWaitForTransactionReceipt({ hash })

  // Navigate after success
  React.useEffect(() => {
    if (isSuccess && receipt) {
      // Extract id from AllowanceCreated event
      let newId: bigint | null = null
      for (const log of receipt.logs) {
        try {
          const decoded = decodeEventLog({
            abi: USDC_ALLOWANCE_ABI,
            data: log.data,
            topics: log.topics,
            eventName: 'AllowanceCreated',
          })
          newId = (decoded.args as { id?: bigint }).id ?? null
          break
        } catch { /* not this event */ }
      }
      toast.success('Allowance created!')
      if (newId) {
        void navigate(`/${network}/a/${newId.toString()}`)
      } else {
        void navigate(`/${network}`)
      }
    }
  }, [isSuccess, receipt, network, navigate])

  const applyPreset = (key: keyof typeof PRESETS) => {
    const p = PRESETS[key].form
    setForm(f => ({ ...f, ...p }))
  }

  const expiresDate = form.expiresAt ? new Date(form.expiresAt) : null

  const validate = () => {
    const err = validateRules({
      spender: form.spender,
      perPaymentCap: form.perPaymentCap,
      periodCap: form.periodCap,
      periodLength: effectivePeriod,
      expiresAt: expiresDate,
      loosenDelay: form.loosenDelay,
      useAllowlist: form.useAllowlist,
      payees: form.payees.filter(Boolean),
    })
    setValidationError(err)
    return err === null
  }

  const handleSubmit = async () => {
    if (!isConnected || !address) { toast.error('Connect your wallet first.'); return }
    if (!validate()) return

    if (chainId !== cfg.chain.id) {
      switchChain({ chainId: cfg.chain.id })
      return
    }

    const expiresS = BigInt(Math.floor(expiresDate!.getTime() / 1000))
    const anchor = form.utcAligned ? 0n : BigInt(Math.floor(Date.now() / 1000))
    const validPayees = form.payees.filter(p => /^0x[0-9a-fA-F]{40}$/.test(p)) as `0x${string}`[]
    const funding = form.funding ? parseEther(form.funding) : 0n
    const maxFee = await getDynamicMaxFee(cfg.chain)

    reset()
    try {
      writeContract({
        address: cfg.address,
        abi: USDC_ALLOWANCE_ABI,
        functionName: 'createAllowance',
        args: [
          form.spender as `0x${string}`,
          {
            perPaymentCap: parseEther(form.perPaymentCap),
            periodCap: parseEther(form.periodCap),
            periodLength: BigInt(effectivePeriod),
            periodAnchor: anchor,
            expiresAt: expiresS,
            loosenDelay: form.loosenDelay,
            useAllowlist: form.useAllowlist,
          },
          validPayees,
          form.label,
        ],
        value: funding,
        maxFeePerGas: maxFee,
        maxPriorityFeePerGas: PRIORITY_FEE,
        chainId: cfg.chain.id,
      })
      toast.loading('Confirm in wallet…', { id: 'create' })
    } catch (e) {
      const msg = decodeContractError(e)
      if (msg !== '__user_rejected__') toast.error(msg)
    }
  }

  React.useEffect(() => {
    if (writeError) {
      toast.dismiss('create')
      const msg = decodeContractError(writeError)
      if (msg !== '__user_rejected__') toast.error(msg)
    }
  }, [writeError])

  return (
    <div className="max-w-xl mx-auto px-4 py-8 space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-gray-900">New allowance</h1>
        <div className="flex gap-2">
          {Object.entries(PRESETS).map(([k, p]) => (
            <button
              key={k}
              onClick={() => applyPreset(k as keyof typeof PRESETS)}
              className="text-xs px-2.5 py-1.5 bg-red-50 text-red-700 rounded-lg hover:bg-red-100 transition-colors font-medium"
            >
              {p.label}
            </button>
          ))}
        </div>
      </div>

      <div className="bg-white rounded-xl border border-gray-200 p-5 space-y-4">
        {/* Spender */}
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">Spender address <span className="text-red-500">*</span></label>
          <input
            type="text"
            value={form.spender}
            onChange={e => set('spender', e.target.value)}
            placeholder="0x…"
            className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500"
          />
          <p className="text-xs text-gray-400">The AI agent or backend service that will call pay().</p>
        </div>

        {/* Label */}
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">Label</label>
          <input
            type="text"
            value={form.label}
            onChange={e => set('label', e.target.value.slice(0, 32))}
            placeholder="research-agent"
            maxLength={32}
            className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
          />
          <p className="text-xs text-gray-400">{form.label.length}/32 bytes</p>
        </div>

        {/* Caps */}
        <div className="grid grid-cols-2 gap-4">
          <AmountInput
            label="Per-payment cap *"
            value={form.perPaymentCap}
            onChange={v => set('perPaymentCap', v)}
            hint="Max per single payment"
          />
          <AmountInput
            label="Period cap *"
            value={form.periodCap}
            onChange={v => set('periodCap', v)}
            hint="Max total per period"
          />
        </div>

        {/* Period */}
        <div className="space-y-2">
          <label className="text-sm font-medium text-gray-700">Period</label>
          <div className="flex flex-wrap gap-2">
            {PERIOD_OPTIONS.map(o => (
              <button
                key={o.value}
                onClick={() => set('periodLength', o.value)}
                className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
                  form.periodLength === o.value
                    ? 'bg-red-600 text-white border-red-600'
                    : 'border-gray-300 text-gray-600 hover:border-red-400'
                }`}
              >
                {o.label}
              </button>
            ))}
          </div>
          {form.periodLength === -1 && (
            <input
              type="number"
              min="60"
              value={form.customPeriod}
              onChange={e => set('customPeriod', e.target.value)}
              placeholder="Seconds (min 60)"
              className="w-40 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
            />
          )}
          {form.periodLength === 86400 && (
            <label className="flex items-center gap-2 text-xs text-gray-600 cursor-pointer">
              <input
                type="checkbox"
                checked={form.utcAligned}
                onChange={e => set('utcAligned', e.target.checked)}
                className="w-3.5 h-3.5 accent-red-600"
              />
              UTC-aligned (anchor = today midnight)
            </label>
          )}
        </div>

        {/* Expiry */}
        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">Expiry *</label>
          <input
            type="datetime-local"
            value={form.expiresAt}
            onChange={e => set('expiresAt', e.target.value)}
            className="w-full px-3 py-2.5 border border-gray-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-red-500"
          />
        </div>

        {/* Advanced */}
        <button
          onClick={() => setShowAdvanced(v => !v)}
          className="flex items-center gap-1 text-xs text-gray-500 hover:text-gray-700"
        >
          {showAdvanced ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
          Advanced options
        </button>

        {showAdvanced && (
          <div className="space-y-4 pt-2 border-t border-gray-100">
            {/* Loosen delay */}
            <div className="space-y-1">
              <label className="text-sm font-medium text-gray-700">Loosen delay</label>
              <div className="flex flex-wrap gap-2">
                {DELAY_OPTIONS.map(o => (
                  <button
                    key={o.value}
                    onClick={() => set('loosenDelay', o.value)}
                    className={`text-xs px-3 py-1.5 rounded-lg border transition-colors ${
                      form.loosenDelay === o.value
                        ? 'bg-red-600 text-white border-red-600'
                        : 'border-gray-300 text-gray-600 hover:border-red-400'
                    }`}
                  >
                    {o.label}
                  </button>
                ))}
              </div>
              <p className="text-xs text-gray-400">How long looser limits take to activate. Tighter limits always apply immediately.</p>
            </div>

            {/* Allowlist */}
            <div className="space-y-2">
              <label className="flex items-center gap-2 text-sm font-medium text-gray-700 cursor-pointer">
                <input
                  type="checkbox"
                  checked={form.useAllowlist}
                  onChange={e => set('useAllowlist', e.target.checked)}
                  className="w-4 h-4 accent-red-600"
                />
                Payee allowlist
              </label>
              {form.useAllowlist && (
                <div className="space-y-2 pl-6">
                  {form.payees.map((p, i) => (
                    <div key={i} className="flex gap-2">
                      <input
                        type="text"
                        value={p}
                        onChange={e => {
                          const updated = [...form.payees]
                          updated[i] = e.target.value
                          set('payees', updated)
                        }}
                        placeholder="0x…"
                        className="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-red-500"
                      />
                      <button
                        onClick={() => set('payees', form.payees.filter((_, j) => j !== i))}
                        className="p-2 text-gray-400 hover:text-red-600 transition-colors"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  ))}
                  {form.payees.length < 20 && (
                    <button
                      onClick={() => set('payees', [...form.payees, ''])}
                      className="flex items-center gap-1.5 text-xs text-red-600 hover:text-red-800"
                    >
                      <Plus className="w-3.5 h-3.5" /> Add payee
                    </button>
                  )}
                </div>
              )}
            </div>
          </div>
        )}

        {/* Initial funding */}
        <AmountInput
          label="Initial funding (optional)"
          value={form.funding}
          onChange={v => set('funding', v)}
          hint="Native USDC deposited with the create transaction"
        />

        {/* Validation error */}
        {validationError && (
          <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{validationError}</p>
        )}

        {chainId !== undefined && chainId !== cfg.chain.id && (
          <p className="text-sm text-yellow-700 bg-yellow-50 px-3 py-2 rounded-lg">
            Wrong network. Click Create to switch to {cfg.chain.name}.
          </p>
        )}

        <TxButton
          onClick={() => { void handleSubmit() }}
          disabled={!isConnected}
          isPending={isPending}
          isConfirming={isConfirming}
          className="w-full"
        >
          Create allowance
        </TxButton>
      </div>
    </div>
  )
}
