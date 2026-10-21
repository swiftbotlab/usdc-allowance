# [App Name]

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

UsdcAllowance is a spending-limit vault on Arc where native USDC (18-decimal, msg.value) can be deposited into per-spender allowances. Owners create allowances with rules (per-payment cap, period cap, expiry, allowlist, loosenDelay). Spenders call pay() to pay payees. Supports pause, revoke, withdraw, and setLimits with delayed loosening.

## Deployed Contracts

| Contract | Network | Address | Tx Hash |
|---|---|---|---|
| UsdcAllowance | Arc Testnet | 0x002b6858223b8e3fb2d105859e69839684a4bd17 | 0xf8c834bf3ed58a664d85556225f010190ff20c728be114e0c0b563a2ed4476ad |
| UsdcAllowance (v1, superseded) | Arc Testnet | 0x03afd38ce9cc62061d2470649295b378a3ad8fc5 | 0x000ff823011b1daf58dd48d338573feaba9f5d40fa6f404faac006536327a27b |

ABI: `contracts/contract-metadata/UsdcAllowance.json`

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## To Run

```bash
bun install
bun run dev
```
