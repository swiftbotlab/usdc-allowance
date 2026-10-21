/**
 * Sends a pay() transaction signed by the agent's private key wallet.
 * Returns the transaction hash.
 */
import {
  createPublicClient,
  createWalletClient,
  http as httpTransport,
  keccak256,
  toBytes,
  parseEther,
  parseGwei,
  decodeEventLog,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import type { Chain } from 'viem'
import { USDC_ALLOWANCE_ABI } from '../config/abi'

export interface PayResult {
  hash: `0x${string}`
  success: boolean
  paidLogFound: boolean
  failureReason?: string
}

export async function agentPay(opts: {
  privateKey: `0x${string}`
  chain: Chain
  contractAddress: `0x${string}`
  id: bigint
  payee: `0x${string}`
  amount: string   // decimal USDC string e.g. "0.05"
  requestId: string
  memo: string
}): Promise<PayResult> {
  const { privateKey, chain, contractAddress, id, payee, amount, requestId, memo } = opts
  const account = privateKeyToAccount(privateKey)

  const pub = createPublicClient({ chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })
  const wallet = createWalletClient({ account, chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })

  const block = await pub.getBlock({ blockTag: 'latest' })
  const base = block.baseFeePerGas ?? parseGwei('10')
  const maxFee = base * 2n > parseGwei('21') ? base * 2n : parseGwei('21')

  const ref = keccak256(toBytes(requestId))

  const hash = await wallet.writeContract({
    address: contractAddress,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'pay',
    args: [id, payee, parseEther(amount), ref, memo],
    maxFeePerGas: maxFee,
    maxPriorityFeePerGas: parseGwei('1'),
    gas: 150000n,
  })

  const receipt = await pub.waitForTransactionReceipt({ hash })
  const success = receipt.status === 'success'

  // Verify Paid log
  let paidLogFound = false
  if (success) {
    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({ abi: USDC_ALLOWANCE_ABI, data: log.data, topics: log.topics })
        if (decoded.eventName === 'Paid') {
          const args = decoded.args as { id: bigint; payee: `0x${string}`; ref: `0x${string}`; amount: bigint }
          if (
            args.id === id &&
            args.payee.toLowerCase() === payee.toLowerCase() &&
            args.ref === ref &&
            args.amount >= parseEther(amount)
          ) {
            paidLogFound = true
          }
        }
      } catch { /* skip non-matching */ }
    }
  }

  return { hash, success, paidLogFound }
}

/**
 * Sends pay() with a fixed gas limit of 150000 so a failing transaction is still
 * visible on the explorer (used for the "Send anyway" button on the cap-exceeded query).
 */
export async function agentPayForceOnchain(opts: {
  privateKey: `0x${string}`
  chain: Chain
  contractAddress: `0x${string}`
  id: bigint
  payee: `0x${string}`
  amount: string
  requestId: string
  memo: string
}): Promise<{ hash: `0x${string}`; success: boolean }> {
  const { privateKey, chain, contractAddress, id, payee, amount, requestId, memo } = opts
  const account = privateKeyToAccount(privateKey)

  const pub = createPublicClient({ chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })
  const wallet = createWalletClient({ account, chain, transport: httpTransport(chain.rpcUrls.default.http[0]) })

  const block = await pub.getBlock({ blockTag: 'latest' })
  const base = block.baseFeePerGas ?? parseGwei('10')
  const maxFee = base * 2n > parseGwei('21') ? base * 2n : parseGwei('21')

  const ref = keccak256(toBytes(requestId))

  const hash = await wallet.writeContract({
    address: contractAddress,
    abi: USDC_ALLOWANCE_ABI,
    functionName: 'pay',
    args: [id, payee, parseEther(amount), ref, memo],
    maxFeePerGas: maxFee,
    maxPriorityFeePerGas: parseGwei('1'),
    gas: 150000n,
  })

  const receipt = await pub.waitForTransactionReceipt({ hash })
  return { hash, success: receipt.status === 'success' }
}
