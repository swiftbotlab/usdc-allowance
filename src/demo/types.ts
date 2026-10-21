export type DemoStep = 1 | 2 | 3 | 4 | 5

export type Speaker = 'Agent' | 'Contract' | 'DataAPI' | 'System'

export interface LogEntry {
  id: number
  ts: number
  speaker: Speaker
  text: string
  txHash?: `0x${string}`
  explorerBase?: string
  isError?: boolean
}

export interface QueryDef {
  label: string
  slug: string
  sampleData: string
}

export const QUERIES: QueryDef[] = [
  { label: 'ETH price',    slug: 'eth-price',    sampleData: 'ETH/USD: $3,421.07 (sample)' },
  { label: 'BTC price',    slug: 'btc-price',    sampleData: 'BTC/USD: $68,204.50 (sample)' },
  { label: 'SOL price',    slug: 'sol-price',    sampleData: 'SOL/USD: $172.33 (sample)' },
  { label: 'USDC supply',  slug: 'usdc-supply',  sampleData: 'USDC total supply: 44.1 B (sample)' },
]

export interface NetAmounts {
  price: string       // per-query payment
  perPaymentCap: string
  periodCap: string
  fund: string
  gasDrop: string     // native transfer to agent for gas
}

export const NET_AMOUNTS: Record<'mainnet' | 'testnet', NetAmounts> = {
  testnet: { price: '0.05', perPaymentCap: '0.10', periodCap: '0.15', fund: '0.30', gasDrop: '0.01' },
  mainnet: { price: '0.01', perPaymentCap: '0.02', periodCap: '0.03', fund: '0.04', gasDrop: '0.01' },
}
