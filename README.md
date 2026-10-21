# USDC Allowance — Swift Bot Labs

Onchain spending limits for AI agents and automated services on Arc.

Owners create an *allowance* — a funded vault with a per-payment cap, a period budget, an expiry, and an optional payee allowlist. An AI agent or backend service is designated as the *spender* and calls `pay()` to disperse funds. The contract enforces every rule on every payment, on-chain, before any funds move.

## Live

- **Mainnet:** `https://swiftbotlab.github.io/usdc-allowance/#/mainnet`
- **Testnet:** `https://swiftbotlab.github.io/usdc-allowance/#/testnet`

## Contracts

| Network | Address |
|---|---|
| Arc Mainnet | `0xbb2f223d3591697e490826cbab2a59aaf507382c` |
| Arc Testnet | `0x002b6858223b8e3fb2d105859e69839684a4bd17` |

Contract on Arc Mainnet: [explorer.arc.io/address/0xbb2f...382c](https://explorer.arc.io/address/0xbb2f223d3591697e490826cbab2a59aaf507382c) (source verified, exact match).
Arc Studio project: https://studio.arc.io/app/b19a3490-bdd3-4635-8082-d24499a7623b

## Real USDC on Arc Mainnet (allowance #1)

Funded 0.20 = paid 0.16 to the data API + refunded 0.04 to the owner; the contract holds 0 afterwards. All roles are fresh keys.

| # | What happened | USDC | Tx |
|---|---|---|---|
| 1 | Deploy the Studio-built contract (byte-identical to Studio's testnet deploy, source verified) | gas only | [0x98184e98...](https://explorer.arc.io/tx/0x98184e98b4ec01e0aa02d39fc3250334de4a88b295ab8434bf9151492506ec34) |
| 2 | Owner creates allowance #1 for a fresh agent key: 0.20 USDC, 0.06 per payment, 0.12 per 5 minutes, data API allowlisted | 0.20 in | [0x8bbb1dfa...](https://explorer.arc.io/tx/0x8bbb1dfa27a314d7544892eaa857242498aadabb59339e067285abdf5451b75f) |
| 3 | Agent pays the data API, ref req-1, memo GET /v1/prices?symbol=ETH | 0.04 | [0x8549b47e...](https://explorer.arc.io/tx/0x8549b47e715d5c5027a349b3e372041620234283ec9dad94d60ea5f36b54084d) |
| 4 | Agent pays, ref req-2 (BTC) | 0.04 | [0x1b9a7cf0...](https://explorer.arc.io/tx/0x1b9a7cf0fd6aaf4ce94a655f588b6c9888c86fc9f48c935ef78de901ec921486) |
| 5 | Agent pays, ref req-3 (SOL) | 0.04 | [0x34027d96...](https://explorer.arc.io/tx/0x34027d96455bc0ba150d54fb806f94656d5c0f1ad5ff7ecd0ff8c6ce613e288b) |
| 6 | 4th payment REFUSED on-chain by the contract: ExceedsPeriodCap(0.04 asked, 0 left) | failed, 0 moved | [0x7f6e9ccd...](https://explorer.arc.io/tx/0x7f6e9ccd345862e8f3ef95c64c52df183ab81cdd187e962f5122181775ed0865) |
| 7 | Owner raises the period cap 0.12 -> 0.16: pending for the 120 s loosen delay | - | [0x4b2693e9...](https://explorer.arc.io/tx/0x4b2693e9138d57afcd253a3e91ac2ddd61734cc4e74788df72453c75db25f4c9) |
| 8 | Owner pauses | - | [0xb25a174c...](https://explorer.arc.io/tx/0xb25a174c83c7b6543d39aa3cb5eaf91f3fe850500e687d01377a3ae93100539e) |
| 9 | Owner unpauses | - | [0xfc4e204d...](https://explorer.arc.io/tx/0xfc4e204df0865d0d54ba72c1cc7ac3acc372aa729c13fb6694a2c6e7bb49021c) |
| 10 | Next period: the 4th payment goes through (ref req-4, GET /v1/supply?asset=USDC) | 0.04 | [0xb282aa75...](https://explorer.arc.io/tx/0xb282aa75c6dd37fcac84667f91be9cb1e4601bae7d3bba51ea31556124d45558) |
| 11 | Owner revokes: the unspent 0.04 returns to the owner | 0.04 back | [0xdb1ba275...](https://explorer.arc.io/tx/0xdb1ba275f650500033290a8567bb9e666feba5a6664f59a4e3394f7d6af8199b) |

The same story ran first on Arc Testnet against Studio's deployment (allowance #1 on `0x002b...bd17`).

**Through the live app (Demo page, allowance #3, in-browser agent key):** create + fund 0.04
([0xc26a...](https://explorer.arc.io/tx/0xc26abaac7ce9b7ad7eaf7f26f876b2983da02bbe0356348f7a7f797f90981393)), gas to the agent
([0xe9bf...](https://explorer.arc.io/tx/0xe9bf3a6dc4e3dee48aaf5e452fec69069b044996224e33b1a4da4052ab6fc4b6)), three paid queries
([0xf92b...](https://explorer.arc.io/tx/0xf92b31ff9a17db919d0b13a36e3c8330566379362e44b34a8cab3ef7c436937b),
[0x9e6d...](https://explorer.arc.io/tx/0x9e6db18df8e69fed3ac4321cc46a4a86ac3641c46bbf3d480cf43e374fc32524),
[0xbe1c...](https://explorer.arc.io/tx/0xbe1cff475420139788e53a3af08480f583f88ed23db335b2f81e751cf75219ec)), the 4th sent anyway and FAILED on-chain with
ExceedsPeriodCap ([0x6c03...](https://explorer.arc.io/tx/0x6c03242f6e804f9a9cde169a431326b5e96d819a7df590c024a8e009471f7b67)), paid after the period reset
([0x24d2...](https://explorer.arc.io/tx/0x24d24a5761db6f7e52c33d57b3a621bf9884a405ac87237205c8d91b7227afdd)), revoke
([0xabdb...](https://explorer.arc.io/tx/0xabdb7c3d9d0cd15a1fc35c6e7d736c970f17ae92ac47d9ebbb5784040c38e1f7)).

Video walkthrough (2:46): https://github.com/swiftbotlab/usdc-allowance/releases/download/v1.0.0/usdc-allowance-arc-studio-mainnet.mp4

## How Arc Studio was used

1. **Contract turn (smart-contract pipeline):** from our written spec Studio wrote `contracts/UsdcAllowance.sol`, six Foundry test files
   (unit, periods, limits, payees, fuzz, a stateful invariant handler), ran its solidity and functional auditors (no findings) and Slither
   (two Medium findings, both reviewed as false positives and documented inline), and deployed to Arc Testnet.
2. **Fix turn (pipeline):** our independent spec suite found that `budget()` did not cap `remainingInPeriod` by the balance; Studio fixed
   it, added tests and an invariant for it, re-ran everything and redeployed (`0x002b...bd17`). Studio reported 106/106 green, invariants at 256 runs x 500 calls.
3. **App turn:** the React app (Owner, New, Allowance, Spender, Demo pages, decoded errors, CSP, frame guard) from one prompt, then
   `bun run check` and `bun run build`.
4. **App fix turn:** after our end-to-end review: the guided agent Demo (in-browser agent key, 4 paid queries, the refused 4th with
   countdown, "Send anyway", revoke), "applies now / applies at" labels, dynamic gas fees, removed a stray CNAME.

Everything under `src/`, `contracts/`, `scripts/` and the configs is synced unchanged from the Studio workspace. Our own additions: this
README's mainnet/Studio/verification sections, `SECURITY.md`, `logo.png`, `spec-tests/` and `.github/workflows/pages.yml`.
Four disclosed hand edits to Studio's code (a few lines each): `src/demo/types.ts` gives the demo agent 0.02 USDC for gas instead of 0.01 (at Arc's
20 gwei base fee the wallet reserves 2x base per tx, so 0.01 ran out before the "Send anyway" and after-reset payments).
`src/pages/DemoPage.tsx`: the read-only replay falls back to the configured `demoAllowanceId` (mainnet #1) when this browser has no
demo of its own, as specified; Studio's version only replayed an id stored in localStorage, so first-time visitors saw no replay.
`src/pages/AllowancePage.tsx`: the History list decodes each log with the ABI (`decodeEventLog`); Studio's version labelled every
entry "Event".
`src/pages/DemoPage.tsx`: the agent's gas top-up is sent with `sendTransaction` (a plain transfer); Studio's version called
`writeContract` with an empty ABI, which never sent anything, so the agent had no gas.

## Verification we ran around Studio

- Studio's own suite, recompiled offline in our sandbox (Foundry 1.x, solc 0.8.28, via-IR): all 100 test functions forge
  counts pass (Studio's report counts 106 incl. invariant properties), invariants at 256 runs, 128,000 calls in total.
- Our independent suite (`spec-tests/`, written before Studio saw the task: 52 unit/fuzz tests + a model-based invariant suite that
  predicts the exact revert data of every call) against Studio's final source: 51/54 pass. The 3 remaining differences are accepted:
  two are Studio's convention for `periodAnchor = 0` (it stores the UTC midnight of creation and counts `periodIndex` from there; the
  period boundaries are the same UTC days), one is a test artifact (that fuzz test reads `block.timestamp` after `vm.warp`, which via-IR
  caches; it fails the same way on our reference contract).
- Mainnet bytecode is byte-identical to Studio's testnet deployment (checked by our deploy script before sending).
- The demo story ran twice with every amount checked to the wei (58 checks each on testnet and mainnet), including the on-chain refusal.

## Stack

- Vite + React + TypeScript
- wagmi / viem injected wallet
- Tailwind CSS v3
- React Router (hash routing for GitHub Pages)
- Deployed to GitHub Pages

## Development

```bash
bun install
bun run dev
```

## Build

```bash
bun run build
# dist/ contains the GitHub Pages artifact
```

## Demo

The `/#/<net>/demo` route walks you through a complete lifecycle titled **"A research agent pays a data API"**.

**Step 1 — Connect the owner wallet.** Connect an injected wallet (MetaMask, Rabby, etc.).

**Step 2 — Create agent key.** Generates a fresh private key in the browser (stored in localStorage under `usdc-allowance:demo-agent:<net>`). The page shows the agent address, its native USDC balance, and a "Forget key" button. The key is hot and intentionally limited — the allowance is what constrains it.

**Step 3 — Fund the allowance.** Two transactions in sequence: `createAllowance(spender = agent, rules = 5-min demo preset, payees = [payee])` funded with USDC, then a plain native USDC transfer to the agent for gas. The payee defaults to your own connected address so the demo costs only gas. Amounts differ by network (testnet: 0.05 USDC/query, 0.30 USDC total; mainnet: 0.01 USDC/query, 0.04 USDC total). The created allowance ID is persisted to localStorage.

**Step 4 — Run agent.** Four queries are sent in order: ETH price, BTC price, SOL price, USDC supply. For each, the agent calls `canPay()` first and, if approved, sends `pay()` signed by the in-browser private key. The Data API verifies the `Paid` log before returning sample data. All calls are shown in a live three-speaker log (Agent / Contract / Data API) with explorer links. The 4th query exceeds the period cap — `canPay` returns reason 9, the page shows a decoded sentence with a live countdown to the period reset, a **Send anyway** button (submits a failing transaction so it appears on the explorer), and a **Try again after reset** button (enabled once the countdown reaches zero).

**Step 5 — Revoke.** Calls `revoke(id)` from the owner wallet. The page shows funded = paid + returned from `getAllowance`.

**Read-only replay.** Without a connected wallet, or before step 3, the page fetches all events for the stored allowance ID and renders them as a chronological log (Paid, Funded, LimitsPending, PausedSet, Revoked, etc.) with explorer links. On Arc Mainnet, allowance #1 is a scripted run: 3 successful payments, the 4th rejected on-chain, the cap raised, a pause/unpause cycle, the 4th payment retried in the next period, and a final revoke.

## Deploy (GitHub Pages)

`.github/workflows/pages.yml` runs the same build in GitHub Actions (`bun install --frozen-lockfile`, `bun run build`) and publishes
`dist/` to https://swiftbotlab.github.io/usdc-allowance/. GitHub Pages cannot send headers, so the production build carries a CSP
meta tag and the app refuses to run inside foreign frames.

## Limitations

One spender per allowance (to change it: revoke and recreate); on-chain data is public; a payee that cannot receive native USDC cannot
be paid; the demo agent key lives in the browser's localStorage. Fixed periods allow up to 2x the period cap across a boundary.

By Swift Bot Labs. MIT licensed. See [SECURITY.md](SECURITY.md).
