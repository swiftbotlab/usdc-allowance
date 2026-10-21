import { decodeErrorResult, parseEther } from 'viem'
import { fmtUsdc } from './format'
import { USDC_ALLOWANCE_ABI } from '../config/abi'

/** Decode a contract custom error into a user-friendly sentence. */
export function decodeContractError(error: unknown): string {
  const msg = (error as { message?: string })?.message ?? String(error)

  // User rejection — silent reset
  if (
    msg.toLowerCase().includes('user rejected') ||
    msg.toLowerCase().includes('user denied') ||
    (error as { code?: number })?.code === 4001
  ) {
    return '__user_rejected__'
  }

  // Try to extract hex error data and decode
  const dataMatch = msg.match(/data['":\s]+"(0x[0-9a-fA-F]+)"/) ||
    msg.match(/(0x[0-9a-fA-F]{8,})/)

  if (dataMatch) {
    try {
      const decoded = decodeErrorResult({
        abi: USDC_ALLOWANCE_ABI,
        data: dataMatch[1] as `0x${string}`,
      })
      return friendlyError(decoded.errorName, decoded.args)
    } catch {
      // fall through
    }
  }

  // Fallback: pattern-match on the message text
  if (msg.includes('AllowanceRevoked'))   return 'This allowance has been permanently revoked.'
  if (msg.includes('AllowanceExpired'))   return 'This allowance has expired.'
  if (msg.includes('AllowancePaused'))    return 'This allowance is currently paused.'
  if (msg.includes('ExceedsPaymentCap')) {
    const m = msg.match(/amount[:\s]+(\d+).*cap[:\s]+(\d+)/i)
    if (m) return `Above the per-payment cap of ${fmtUsdc(BigInt(m[2]))} USDC. Tried ${fmtUsdc(BigInt(m[1]))} USDC.`
    return 'Above the per-payment cap.'
  }
  if (msg.includes('ExceedsPeriodCap')) {
    const m = msg.match(/amount[:\s]+(\d+).*remaining[:\s]+(\d+)/i)
    if (m) return `Exceeds the period cap — only ${fmtUsdc(BigInt(m[2]))} USDC left this period.`
    return 'Exceeds the period spending cap.'
  }
  if (msg.includes('InsufficientBalance')) return 'Insufficient balance in this allowance.'
  if (msg.includes('DuplicateRef'))        return 'This request ID was already paid from this allowance.'
  if (msg.includes('PayeeNotAllowed'))     return 'This payee is not on the allowlist (or not active yet).'
  if (msg.includes('ZeroAmount'))          return 'Amount must be greater than zero.'
  if (msg.includes('NotOwner'))            return 'Only the allowance owner can do this.'
  if (msg.includes('NotSpender'))          return 'Only the assigned spender can pay from this allowance.'
  if (msg.includes('MemoTooLong'))         return 'Memo is too long (max 140 bytes).'
  if (msg.includes('LabelTooLong'))        return 'Label is too long (max 32 bytes).'
  if (msg.includes('InvalidRules'))        return 'One or more rule values are invalid. Check caps, expiry, and period length.'
  if (msg.includes('TooManyPayees'))       return 'An allowance can have at most 20 payees.'
  if (msg.includes('InvalidPayee'))        return 'Invalid payee address (zero, contract itself, or duplicate).'
  if (msg.includes('AllowlistDisabled'))   return 'This allowance does not use a payee allowlist.'
  if (msg.includes('TransferFailed'))      return 'The payment transfer failed — the payee may not be able to receive native USDC.'
  if (msg.includes('insufficient funds') || msg.includes('exceeds balance'))
    return 'Insufficient USDC balance for this transaction (including gas).'

  return `Transaction failed: ${msg.slice(0, 120)}`
}

function friendlyError(name: string, args: readonly unknown[]): string {
  switch (name) {
    case 'AllowanceRevoked':    return 'This allowance has been permanently revoked.'
    case 'AllowanceExpired':    return 'This allowance has expired.'
    case 'AllowancePaused':     return 'This allowance is currently paused.'
    case 'ExceedsPaymentCap':   return `Above the per-payment cap of ${fmtUsdc(args[1] as bigint)} USDC. Tried ${fmtUsdc(args[0] as bigint)} USDC.`
    case 'ExceedsPeriodCap':    return `Only ${fmtUsdc(args[1] as bigint)} USDC left this period (tried ${fmtUsdc(args[0] as bigint)} USDC).`
    case 'InsufficientBalance': return `Insufficient balance. Tried ${fmtUsdc(args[0] as bigint)}, have ${fmtUsdc(args[1] as bigint)} USDC.`
    case 'DuplicateRef':        return 'This request ID was already paid from this allowance.'
    case 'PayeeNotAllowed':     return 'This payee is not on the allowlist (or not active yet).'
    case 'ZeroAmount':          return 'Amount must be greater than zero.'
    case 'NotOwner':            return 'Only the allowance owner can do this.'
    case 'NotSpender':          return 'Only the assigned spender can pay from this allowance.'
    case 'MemoTooLong':         return 'Memo exceeds 140 bytes.'
    case 'LabelTooLong':        return 'Label exceeds 32 bytes.'
    case 'InvalidRules':        return 'One or more rule values are invalid.'
    case 'TooManyPayees':       return 'An allowance can have at most 20 payees.'
    case 'InvalidPayee':        return 'Invalid payee address.'
    case 'AllowlistDisabled':   return 'This allowance does not use a payee allowlist.'
    case 'TransferFailed':      return 'Transfer failed — the payee cannot receive native USDC.'
    case 'UnknownAllowance':    return `Allowance #${String(args[0])} does not exist.`
    default: return `Transaction failed (${name}).`
  }
}

/** Validate create-allowance form fields against contract rules.  Returns first error or null. */
export function validateRules(f: {
  spender: string
  perPaymentCap: string
  periodCap: string
  periodLength: number
  expiresAt: Date | null
  loosenDelay: number
  useAllowlist: boolean
  payees: string[]
}): string | null {
  if (!f.spender || !/^0x[0-9a-fA-F]{40}$/.test(f.spender)) return 'Spender must be a valid address.'
  let per: bigint, period: bigint
  try { per = parseEther(f.perPaymentCap) } catch { return 'Per-payment cap must be a number (e.g. 1).' }
  try { period = parseEther(f.periodCap) } catch { return 'Period cap must be a number.' }
  if (per === 0n) return 'Per-payment cap must be > 0.'
  if (per > period) return 'Per-payment cap cannot exceed the period cap.'
  if (f.periodLength < 60) return 'Period must be at least 60 seconds.'
  if (f.periodLength > 365 * 24 * 3600) return 'Period cannot exceed 365 days.'
  if (!f.expiresAt) return 'Expiry date is required.'
  const nowS = Math.floor(Date.now() / 1000)
  const expiresS = Math.floor(f.expiresAt.getTime() / 1000)
  if (expiresS <= nowS) return 'Expiry must be in the future.'
  if (expiresS > nowS + 3650 * 24 * 3600) return 'Expiry cannot be more than 3650 days from now.'
  if (f.loosenDelay > 30 * 24 * 3600) return 'Loosen delay cannot exceed 30 days.'
  if (f.payees.length > 0 && !f.useAllowlist) return 'Payees can only be set when the allowlist is enabled.'
  if (f.payees.length > 20) return 'Maximum 20 payees.'
  const seen = new Set<string>()
  for (const p of f.payees) {
    if (!p || !/^0x[0-9a-fA-F]{40}$/.test(p)) return `Invalid payee address: ${p}`
    if (p.toLowerCase() === f.spender.toLowerCase()) return `Payee cannot be the spender.`
    if (seen.has(p.toLowerCase())) return `Duplicate payee: ${p}`
    seen.add(p.toLowerCase())
  }
  return null
}
