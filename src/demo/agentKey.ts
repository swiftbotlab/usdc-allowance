import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import type { NetworkKey } from '../config/networks'

const LS_KEY = (net: NetworkKey) => `usdc-allowance:demo-agent:${net}`
const LS_ID_KEY = (net: NetworkKey) => `usdc-allowance:demo-id:${net}`

export interface AgentKey {
  privateKey: `0x${string}`
  address: `0x${string}`
}

export function loadOrCreateAgentKey(net: NetworkKey): AgentKey {
  try {
    const stored = localStorage.getItem(LS_KEY(net))
    if (stored && /^0x[0-9a-fA-F]{64}$/.test(stored)) {
      const acc = privateKeyToAccount(stored as `0x${string}`)
      return { privateKey: stored as `0x${string}`, address: acc.address }
    }
  } catch { /* ignore */ }
  return createAndStoreKey(net)
}

function createAndStoreKey(net: NetworkKey): AgentKey {
  const pk = generatePrivateKey()
  const acc = privateKeyToAccount(pk)
  try { localStorage.setItem(LS_KEY(net), pk) } catch { /* ignore */ }
  return { privateKey: pk, address: acc.address }
}

export function forgetAgentKey(net: NetworkKey): void {
  try {
    localStorage.removeItem(LS_KEY(net))
    localStorage.removeItem(LS_ID_KEY(net))
  } catch { /* ignore */ }
}

export function saveDemoId(net: NetworkKey, id: bigint): void {
  try { localStorage.setItem(LS_ID_KEY(net), id.toString()) } catch { /* ignore */ }
}

export function loadDemoId(net: NetworkKey): bigint | null {
  try {
    const v = localStorage.getItem(LS_ID_KEY(net))
    if (v && /^[1-9]\d*$/.test(v)) return BigInt(v)
  } catch { /* ignore */ }
  return null
}
