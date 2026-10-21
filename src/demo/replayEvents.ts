/**
 * Fetches all events for a given allowance id and returns them as a flat
 * display list (newest last). Used by the read-only replay panel.
 */
import {
  createPublicClient,
  http as httpTransport,
  decodeEventLog,
  formatEther,
} from 'viem'
import type { Chain } from 'viem'
import { USDC_ALLOWANCE_ABI } from '../config/abi'

export interface ReplayEntry {
  blockNumber: bigint
  txHash: `0x${string}`
  eventName: string
  summary: string
}

export async function fetchReplayEvents(
  id: bigint,
  chain: Chain,
  contractAddress: `0x${string}`,
  fromBlock: bigint,
): Promise<ReplayEntry[]> {
  const client = createPublicClient({ chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })
  const head = await client.getBlockNumber()
  const CHUNK = 9000n
  const idTopic = ('0x' + id.toString(16).padStart(64, '0')) as `0x${string}`
  const results: ReplayEntry[] = []

  for (let from = fromBlock; from <= head; from += CHUNK) {
    const to = from + CHUNK - 1n < head ? from + CHUNK - 1n : head
    const logs = await client.getLogs({ address: contractAddress, fromBlock: from, toBlock: to })
    for (const log of logs) {
      if (log.topics[1] !== idTopic) continue
      try {
        const decoded = decodeEventLog({ abi: USDC_ALLOWANCE_ABI, data: log.data, topics: log.topics })
        const summary = summarise(decoded.eventName, decoded.args)
        results.push({
          blockNumber: log.blockNumber ?? 0n,
          txHash: log.transactionHash ?? '0x',
          eventName: decoded.eventName,
          summary,
        })
      } catch { /* unknown event shape */ }
    }
  }

  return results.sort((a, b) => (a.blockNumber < b.blockNumber ? -1 : 1))
}

function fmt(v: bigint): string {
  const s = formatEther(v)
  const [int, frac = ''] = s.split('.')
  const trimmed = frac.slice(0, 4).replace(/0+$/, '')
  return trimmed ? `${int}.${trimmed}` : int
}

function shortAddr(s: string): string {
  if (!s || s.length < 10) return s
  return `${s.slice(0, 6)}…${s.slice(-4)}`
}

function shortRef(b: string): string {
  if (!b || b.length < 10) return b
  return b.slice(0, 10) + '…'
}

function summarise(name: string, args: Record<string, unknown>): string {
  switch (name) {
    case 'Paid':
      return `${fmt(args.amount as bigint)} USDC → ${shortAddr(args.payee as string)}  ref ${shortRef(args.ref as string)}  memo: ${(args.memo as string) ?? ''}`
    case 'Funded':
      return `+${fmt(args.amount as bigint)} USDC  (balance ${fmt(args.balance as bigint)})`
    case 'Withdrawn':
      return `-${fmt(args.amount as bigint)} USDC`
    case 'LimitsChanged':
      return `perCap ${fmt(args.perPaymentCap as bigint)}, periodCap ${fmt(args.periodCap as bigint)}`
    case 'LimitsPending':
      return `perCap ${fmt(args.perPaymentCap as bigint)}, periodCap ${fmt(args.periodCap as bigint)} — active at ${new Date(Number(args.activeAt) * 1000).toLocaleTimeString()}`
    case 'PausedSet':
      return args.paused ? 'Paused' : 'Unpaused'
    case 'Revoked':
      return `Returned ${fmt(args.refunded as bigint)} USDC`
    case 'PayeeAdded':
      return `Added ${shortAddr(args.payee as string)}`
    case 'PayeeRemoved':
      return `Removed ${shortAddr(args.payee as string)}`
    case 'AllowanceCreated':
      return `spender ${shortAddr(args.spender as string)}  label: ${(args.label as string) ?? ''}`
    default:
      return name
  }
}
