import { arcTestnet } from 'viem/chains'
import { defineChain } from 'viem'

export const arcMainnet = defineChain({
  id: 5042,
  name: 'Arc',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.arc.io'] } },
  blockExplorers: { default: { name: 'Arc Explorer', url: 'https://explorer.arc.io' } },
})

export type NetworkKey = 'mainnet' | 'testnet'

export interface NetworkConfig {
  chain: typeof arcTestnet | typeof arcMainnet
  address: `0x${string}`
  deploymentBlock: bigint
  demoAllowanceId: bigint
  explorerBase: string
}

export const NETWORKS: Record<NetworkKey, NetworkConfig> = {
  mainnet: {
    chain: arcMainnet,
    address: '0xbb2f223d3591697e490826cbab2a59aaf507382c',
    deploymentBlock: 27048897n,
    demoAllowanceId: 1n,
    explorerBase: 'https://explorer.arc.io',
  },
  testnet: {
    chain: arcTestnet,
    address: '0x002b6858223b8e3fb2d105859e69839684a4bd17',
    deploymentBlock: 68284718n,
    demoAllowanceId: 1n,
    explorerBase: 'https://explorer.testnet.arc.io',
  },
}

export const DEFAULT_NETWORK: NetworkKey = 'mainnet'

export function getNetwork(key: string | undefined): NetworkKey {
  if (key === 'testnet') return 'testnet'
  return 'mainnet'
}
