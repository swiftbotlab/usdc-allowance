/**
 * wagmi configuration — UsdcAllowance app
 * Supports Arc Mainnet (5042) and Arc Testnet (5042002).
 * Native gas IS USDC on both. Never use the 6-decimal ERC-20 for msg.value flows.
 */

import { http, createConfig } from 'wagmi'
import { mainnet } from 'wagmi/chains'
import { arcTestnet } from 'viem/chains'
import { injected } from 'wagmi/connectors'
import { arcMainnet } from './config/networks'

export const config = createConfig({
  chains: [arcMainnet, arcTestnet, mainnet], // mainnet for ENS only
  connectors: [injected()],
  transports: {
    [arcMainnet.id]: http('https://rpc.mainnet.arc.io'),
    [arcTestnet.id]: http('https://rpc.testnet.arc.io'),
    [mainnet.id]: http(),
  },
})
