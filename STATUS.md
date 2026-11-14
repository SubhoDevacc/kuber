# Kuber — status

**Updated:** 2026-11-14

Live demo: <https://kuber-production.up.railway.app> · Contracts on Avalanche Fuji: `deployments/fuji.json`

## Done

### Contracts (tested, deployed and verified on Fuji)
- Token, two vault mocks, registry, factory, and the circle contract with ten linked libraries.
- Forming and joining, round settlement, investing, loans and a fair queue, backing, defaults and the loss waterfall, voting (rules, money plan, fund manager, removing a member, late joiner), leaving, fund manager, fees, gas reimbursement.
- 353 tests pass: unit tests, the SPEC §4 worked example to the unit, property tests, a stateful invariant suite, a deploy test. Eight planted bugs are each caught. Slither: no high or medium finding.

### Tutorial mode (private practice chain per visitor)
- New users go through it once; it cannot be skipped the first time.
- Starts with a choice: join Bala's circle or create your own. Six chapters, 16 or 17 steps, each a real transaction: save, borrow with a backer, repay, vote in a fund manager, vote on a rule, a member stops paying, share-out.
- Every step shows sent → confirmed → round settled, the real transaction hashes, and a "What just changed" card. Each step is also recorded on Avalanche Fuji with a Snowtrace link.
- After the first run: a "Tutorial mode" switch in the top bar and a chapter picker that sets up a fresh practice circle and fast-forwards to the chosen chapter.
- End payouts match SPEC §4 to the unit on both paths (checked by the server test).

### Real app (Avalanche Fuji, Privy sign-in)
- Sign in with Privy; an embedded wallet is created. New accounts get 20,000 test mUSDC and a little AVAX for gas, once.
- Create a circle, invite people by name, join, save, borrow (choose the interest offered to backers), back a loan by vouching or agreeing with the risk shown in money, repay, vote, suggest a rule change, leave, collect the share-out.
- Fund manager: vote a member in, see who it is and their record, the manager proposes a new money plan (ready to lend, Aave, LP pool, cash) and the group votes; change the manager's fee; remove the manager.
- A keeper starts circles and closes rounds on its own.
- Activity lists for each circle and for the user; every transaction hash opens an in-app details view and links to Snowtrace.

### Hosting and checks
- One container: each tutorial visitor gets a private chain; the real app talks to Fuji.
- Server tests: tutorial end to end (both paths), two users at once through the hosted process, the real app end to end on a local stand-in for Fuji. Web build and tests, lint, version check.

## Mocked for the demo — must become real

Every item below is a real on-chain transaction; what is simplified is who decides or where the numbers come from.

1. **Practice members** (Bala, Chitra, Dev, Esha, Farhan in the tutorial; Gita, Hari, Indu, Jay in the real app) are wallets run by the server. They save, vote yes, back loans and propose on a script. Real version: real people, or an opt-in delegate with its own policy.
2. **The practice manager's money plan is a fixed preset** (40/35/15/10, or 40/25/25/10). Real version: a human manager using "Change the money plan" (works today), or a strategy with a record of why.
3. **Test vaults.** `MockAaveVault` and `MockLPVault` pay simulated interest (5% and 8%) that the server speeds up 21,600 times so a 2-minute round earns about a month of interest. Real version: a real Aave v3 position and a real DEX LP position, live rates, no speed-up.
4. **LP price moves are driven by the server** (up 0.3% most minutes, down 0.2% now and then). Real version: real LP value from an oracle, guarded against manipulation.
5. **"Earned this round" per part** is measured from the last round close and does not net out mid-round payouts. Real version: per-vault accounting in the contract or an indexer.
6. **"You could lose up to"** shows the worst case (the whole pledge). The borrower's own savings are taken first, so the usual loss is smaller. Real version: show the expected loss as well.
7. **Identity check is mocked:** "Verify me" marks the wallet verified; no ID data is collected. Real version: a KYC provider and encrypted storage.
8. **Inviting someone who is not registered** only gives a link to share; the server sends no message.
9. **"Tutorial finished" and "tip shown" are remembered in the browser** per wallet. Real version: stored per account on the server.
10. **Display names are kept in a file on the server** and are lost if the server's disk is replaced (addresses are shown instead). Real version: a database.
11. **The one-grant-per-person limit** is per wallet; the check against the Privy account is written but not proven with a real token.
12. **The tutorial's logic runs on a private practice chain, not Fuji,** so that time can be moved forward. Each step is also recorded on Fuji by a real transaction to `KuberPracticeLog`; that transaction is a public record of the step, not the money movement itself. Real version: run the tutorial on a public network in real time, or run the practice chain as its own Avalanche L1.

## Left (not built)

1. Governance rule: a member whose proposal fails cannot propose in the next round; a rule proposal equal to the current value is rejected.
2. Eight contract test gaps found by the audit (code correct, test missing); gas tests and the 50-member scenario as gate tests; coverage report; the 10,000-run fuzz profile; code, security and second-opinion reviews of the fees and hardening work.
3. Removing a member by vote and late joining with a sponsor have contract support but no screens.
4. Seed data, live APY sync, offline support, end-to-end browser tests in the repo, Lighthouse.
5. A private Fuji RPC endpoint (the public one rate-limits under load).
6. Moving the practice chain to its own Avalanche L1 (today it is a private test chain started by the server for each visitor).

## How to run

See the README: `pnpm install`, `pnpm dev`, open <http://localhost:5173>.
