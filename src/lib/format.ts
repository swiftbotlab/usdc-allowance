import { formatEther } from 'viem'

/** Format 18-decimal native USDC amount to a display string (up to 6 sig decimals). */
export function fmtUsdc(raw: bigint | undefined | null, decimals = 6): string {
  if (raw === undefined || raw === null) return '—'
  const s = formatEther(raw)
  const [int, frac = ''] = s.split('.')
  const trimmed = frac.slice(0, decimals).replace(/0+$/, '')
  return trimmed ? `${int}.${trimmed}` : int
}

/** Format seconds to mm:ss */
export function fmtCountdown(seconds: number): string {
  if (seconds <= 0) return '0:00'
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

/** Shorten an address: 0x1234…5678 */
export function shortAddr(addr: string): string {
  if (!addr || addr.length < 10) return addr
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

/** Shorten a bytes32 ref: 0x1234…abcd */
export function shortBytes32(b: string): string {
  if (!b || b.length < 10) return b
  return `${b.slice(0, 10)}…${b.slice(-6)}`
}

/** Percentage 0-100 */
export function pct(numerator: bigint, denominator: bigint): number {
  if (denominator === 0n) return 0
  return Math.min(100, Number((numerator * 10000n) / denominator) / 100)
}

export const STATUS_LABELS: Record<number, string> = {
  0: 'None',
  1: 'Active',
  2: 'Paused',
  3: 'Expired',
  4: 'Revoked',
}

export const STATUS_COLORS: Record<number, string> = {
  0: 'bg-gray-100 text-gray-500',
  1: 'bg-green-100 text-green-700',
  2: 'bg-yellow-100 text-yellow-700',
  3: 'bg-gray-100 text-gray-500',
  4: 'bg-red-100 text-red-700',
}

export const CAN_PAY_REASONS: Record<number, string> = {
  0: 'OK',
  1: 'Allowance not found',
  2: 'Allowance has been revoked',
  3: 'Allowance has expired',
  4: 'Allowance is paused',
  5: 'Invalid payee address',
  6: 'This payee is not on the allowlist (or not active yet)',
  7: 'Amount must be greater than zero',
  8: 'Above the per-payment cap',
  9: 'Exceeds the period spending cap',
  10: 'Insufficient balance in this allowance',
  11: 'This request ID was already paid',
}
