import { useState, useEffect, useCallback } from 'react'
import { createPublicClient, http, type Log } from 'viem'
import type { NetworkConfig } from '../config/networks'
import { USDC_ALLOWANCE_ABI } from '../config/abi'

export interface HistoryEntry {
  type: string
  blockNumber: bigint
  transactionHash: `0x${string}`
  args: Record<string, unknown>
}

const CHUNK = 9000n

export function useAllowanceHistory(id: bigint | undefined, cfg: NetworkConfig) {
  const [entries, setEntries] = useState<HistoryEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetch = useCallback(async () => {
    if (!id || id === 0n) return
    setLoading(true)
    setError(null)

    const client = createPublicClient({
      chain: cfg.chain,
      transport: http(cfg.chain.rpcUrls.default.http[0]),
    })

    try {
      const head = await client.getBlockNumber()
      const start = cfg.deploymentBlock

      // Event topics for this allowance id (topic1 = id)
      const eventNames = [
        'AllowanceCreated', 'Funded', 'Paid', 'LimitsChanged', 'LimitsPending',
        'PendingCleared', 'PayeeAdded', 'PayeeRemoved', 'PausedSet', 'Withdrawn', 'Revoked',
      ]

      const allLogs: HistoryEntry[] = []

      for (let from = start; from <= head; from += CHUNK) {
        const to = from + CHUNK - 1n < head ? from + CHUNK - 1n : head
        try {
          const logs: Log[] = await client.getLogs({
            address: cfg.address,
            fromBlock: from,
            toBlock: to,
          })
          for (const log of logs) {
            // Match logs to known event signatures
            for (const name of eventNames) {
              try {
                const abiItem = USDC_ALLOWANCE_ABI.find(
                  (e): e is Extract<typeof e, { type: 'event'; name: string }> =>
                    e.type === 'event' && e.name === name
                )
                if (!abiItem) continue
                // Check first indexed topic = id
                const idTopic = '0x' + id.toString(16).padStart(64, '0') as `0x${string}`
                if (log.topics[1] !== idTopic) continue
                // Parse args from log data — simple approach
                allLogs.push({
                  type: name,
                  blockNumber: log.blockNumber ?? 0n,
                  transactionHash: log.transactionHash ?? '0x',
                  args: { ...(log as Record<string, unknown>) },
                })
              } catch { /* skip */ }
            }
          }
        } catch {
          setError('History may be incomplete — some blocks could not be fetched.')
        }
      }

      // Sort by block ascending
      allLogs.sort((a, b) => (a.blockNumber < b.blockNumber ? -1 : a.blockNumber > b.blockNumber ? 1 : 0))
      setEntries(allLogs)
    } catch (e) {
      setError('Failed to load history. ' + String(e))
    } finally {
      setLoading(false)
    }
  }, [id, cfg])

  useEffect(() => { void fetch() }, [fetch]) // eslint-disable-line react/set-state-in-effect

  return { entries, loading, error, retry: fetch }
}
