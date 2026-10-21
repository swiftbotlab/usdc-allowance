import { createPublicClient, http as httpTransport, parseGwei } from 'viem'
import type { Chain } from 'viem'

/** Fetch latest base fee and return max(2 × baseFee, 21 gwei). */
export async function getDynamicMaxFee(chain: Chain): Promise<bigint> {
  try {
    const client = createPublicClient({ chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })
    const block = await client.getBlock({ blockTag: 'latest' })
    const base = block.baseFeePerGas ?? parseGwei('10')
    const doubled = base * 2n
    const floor = parseGwei('21')
    return doubled > floor ? doubled : floor
  } catch {
    return parseGwei('21')
  }
}

/** Synchronous fallback used when we already have a prefetched fee. */
export function safeMaxFee(baseFeePerGas: bigint | null | undefined): bigint {
  const base = baseFeePerGas ?? parseGwei('10')
  const doubled = base * 2n
  const floor = parseGwei('21')
  return doubled > floor ? doubled : floor
}

export const PRIORITY_FEE = parseGwei('1')
