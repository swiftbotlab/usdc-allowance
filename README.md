# USDC Allowance

Spending limits for software that pays: give an agent a USDC budget on Arc, not your wallet.

A single contract holds the USDC; an agent key may only pay within the limits its owner set: a per-payment cap, a
per-period cap, a payee allowlist, an expiry and a pause switch. Tightening applies at once, loosening waits for a delay,
and revoke returns the rest. The contract, its tests and the web app are being built with Arc Studio; this repository
will carry the Studio workspace, the deployments and the GitHub Pages build.

- `spec-tests/`: our independent Foundry suite for the specification (unit, fuzz and a stateful invariant suite).
- [SECURITY.md](SECURITY.md): guarantees and known limitations.

By Swift Bot Labs. MIT licensed.
