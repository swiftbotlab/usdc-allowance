# Security

USDC Allowance is a single Solidity contract (`contracts/UsdcAllowance.sol`) and a static web app. Report problems through
a GitHub issue on this repository (for anything that could put funds at risk, open an issue that only says "security
contact please" and we will reach out).

## What the contract guarantees
- No admin, no fees, no upgrades, no `receive()`: USDC only enters through `createAllowance` and `fund`, and only leaves
  through `pay` (to a payee, by the allowance's spender), `withdraw` and `revoke` (to the allowance's owner).
- Every payment is checked, in a fixed order, against: revoked, expiry, pause, payee validity, the payee allowlist (with
  per-payee activation time), the per-payment cap, the per-period cap, the balance, and the one-time `ref`. `canPay` runs
  the exact same check, so an agent or a payee can preflight a payment without sending it.
- Periods are fixed windows (`periodAnchor + k * periodLength`). The cap applies per window; across a window boundary a
  spender can pay up to twice the cap within one period length (documented trade-off for O(1) gas).
- Tighten now, loosen later: lower caps, an earlier expiry, removing a payee and pausing apply immediately. Higher caps, a
  later expiry and new payees apply only after the allowance's `loosenDelay`, so a tricked owner signature cannot open the
  tap at once. `revoke` is final and returns the whole unspent balance to the owner.
- Accounting: for every allowance `totalFunded == balance + totalPaid + totalRefunded`, and the contract balance equals
  `totalHeld`, the sum of all balances.
- Every state-changing function is `nonReentrant`, and the transfer happens after all effects and the event. A payee that
  cannot receive native USDC makes that one payment revert and changes nothing (its `ref` is not used up).

## Known limitations
- The spender key is a hot key by design: the allowance limits what a leaked or misbehaving key can spend, it does not
  stop it from spending within the limits. Use a small cap, a short period and the allowlist.
- One spender per allowance and no spender change: to rotate a key, revoke and create a new allowance.
- Labels, memos and refs are public, untrusted text; the app renders them as plain text only.
- The Demo page stores a throwaway agent key in the browser's localStorage. Use it with tiny amounts only.
- The app is served by GitHub Pages, which cannot send `X-Frame-Options` / `frame-ancestors` headers; the app refuses to
  run inside frames other than Arc Studio's preview. Your wallet still shows every transaction before you sign.

## Testing
Foundry unit, fuzz and stateful invariant tests (`contracts/test/`), including a model-based handler that predicts the exact
revert data of every call. The deployed mainnet bytecode is byte-identical to the Arc Testnet deployment made by Arc Studio
(checked by our deploy script before sending), and the source is verified on explorer.arc.io.
