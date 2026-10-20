# PoC — Morpheus DistributorV2: donation-steered MOR emission split

Foundry fork test demonstrating that `DistributorV2.distributeRewards`
measures each DepositPool's yield as the Distributor's raw ERC20 balance
delta, so an unprivileged attacker can steer the MOR emission split toward
a pool they dominate with a plain ERC20 donation of that pool's yield token.

## Run

```bash
forge test --match-test test_DonationSteersEmission -vv
```

One command. Forks Ethereum mainnet at block **26232694** via the public
RPC endpoint configured in `foundry.toml` (no API key). No other setup.

## What the test does

Two runs from the same fork snapshot, attacker is a fresh address with no
privileges in both:

- **Control:** attacker stakes 47,390 USDT in the USDT DepositPool, waits,
  distribution runs, attacker claims. Claimable: **1,571.057249 MOR**.
- **Attack:** identical, except before the distribution the attacker
  donates 5,196,999,999 aUSDT (Aave aToken, ~$5,197) to the Distributor
  with a plain `transfer`. The USDT pool is credited 84.48% of the period
  emission instead of 6.48%. Attacker claims **20,477.279415 MOR**.

**Excess captured: 18,906.222166 MOR (13.03× the honest claim)** for a
~$5,197 irrecoverable donation. `distributeRewards` is permissionless —
the attacker calls it directly in both runs.

## Disclosed harness accommodations

- The attacker is funded with `deal()` (USDT + ETH). Every protocol
  interaction is the attacker's own call; no owner/admin is impersonated
  anywhere.
- Third-party Chainlink aggregators' `latestRoundData()` is mocked with
  each feed's **real answer at the fork block** and a fresh timestamp.
  This is unavoidable on a fork: the test warps >86,400s (distribution
  period) and 14 days (claim lock), while the feeds' staleness delays are
  3600s/86400s — unmocked, every price reads stale and the distribution
  reverts with `DR: price for pair is zero`. No Morpheus contract, config,
  or price value is altered.
- MOR mints on Arbitrum via LayerZero, so on L1 the claimed amount is
  proven by the `UserClaimed` / `MintMessageSent` amounts, which the test
  asserts exactly; claimable balances are zeroed after claiming in both
  runs.
