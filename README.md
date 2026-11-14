# Kuber

A savings circle on Avalanche where the rules hold the money, not a person.

A small group saves the same amount each round. The pooled money is put to work. Members can borrow against their own savings, or borrow more when other members back them. If a borrower stops paying, their own savings pay first, then only the members who backed them. **If you backed nobody, nobody else's default can touch your savings.**

Built by Subham Mandal.

## Try it (about 3 minutes)

You need [Foundry](https://getfoundry.sh) 1.9, Node 26 and pnpm 12.

```sh
git clone --recurse-submodules https://github.com/SubhoDevacc/kuber.git
cd kuber
pnpm install
pnpm dev
```

Then open <http://localhost:5173>.

`pnpm dev` starts a controlled test environment on your machine:

| Part | What it does |
|---|---|
| Local chain (Anvil, port 8545) | Runs the real Kuber contracts |
| Server (port 8787) | Signs you up, gives you 20,000 test mUSDC, runs five practice members, and moves time so you never wait for a round |
| Web app (port 5173) | The app and its tutorial |

Tap **Start**, pick a name, and the tutorial opens. It is a real practice circle with six members. Every step you take is a real transaction with the real contracts, signed by a practice wallet in your browser.

| Chapter | What you do | What you see |
|---|---|---|
| 1. Join and save | Join; rounds close | Everyone saves 100 a round; the pot is put to work |
| 2. Borrow | Ask for 350 | 270 against your own savings, 80 backed by Bob |
| 3. Repay | Two payments | Bob earns 6.40 for backing you |
| 4. Vote | Vote on a rule | A change passes with more than half of the members |
| 5. A member stops paying | Watch | Dave's own savings pay 300 first; his backers Cara and Erin lose 30 and 20; Frank and you lose nothing |
| 6. Share-out | Collect | You get 712.04 back from 700 saved |

These numbers are the worked example in `docs/SPEC.md` §4. The contract tests and the server's end-to-end test both check them to the last unit.

## Contracts on Avalanche Fuji

Deployed and verified (Sourcify; shown on Snowtrace). Chain id 43113. Addresses are also in `deployments/fuji.json`.

| Contract | Address |
|---|---|
| KuberFactory | [`0xcD0a42d583FfC8828Dd1AF763fe8f296CC80e2aB`](https://testnet.snowtrace.io/address/0xcD0a42d583FfC8828Dd1AF763fe8f296CC80e2aB) |
| KuberCircle (implementation) | [`0x76bC1C04dbd2e92aCc94E30dACf1a787B3431B25`](https://testnet.snowtrace.io/address/0x76bC1C04dbd2e92aCc94E30dACf1a787B3431B25) |
| KuberRegistry | [`0x42B7952635687C695036BAe1de7f67c2E7eC00B0`](https://testnet.snowtrace.io/address/0x42B7952635687C695036BAe1de7f67c2E7eC00B0) |
| MockUSDC (test token) | [`0x2d2345237E7B49b252b4be208E91366A6EF08105`](https://testnet.snowtrace.io/address/0x2d2345237E7B49b252b4be208E91366A6EF08105) |
| MockAaveVault | [`0x73F22060975713baEfB0fF11120de7e9c4236849`](https://testnet.snowtrace.io/address/0x73F22060975713baEfB0fF11120de7e9c4236849) |
| MockLPVault | [`0xe7AcB6DB6BD00126981762d69dF65BE4B64C2be9`](https://testnet.snowtrace.io/address/0xe7AcB6DB6BD00126981762d69dF65BE4B64C2be9) |

The circle contract links ten libraries (Forming, Settle, ShareOut, Invest, Queue, Loans, Backing, Waterfall, Governance, Membership); their addresses are in `deployments/fuji.json` and they are verified too.

The tutorial itself runs on the local chain, not on Fuji, because it needs to move time forward between rounds.

## What the contracts do

- **Circles:** create, invite, join, start; fixed contribution per round; settlement in batches of members.
- **Investing:** the pot is split between cash, a loan reserve and two vaults, by an allocation the members can vote on.
- **Loans:** borrow against your own savings; larger loans need backers; a fair queue; fines for late payments.
- **Defaults:** the borrower's savings first, then backers in proportion to their pledges; a debt that follows the borrower across circles.
- **Governance:** proposals and votes for rules, allocation, a fund manager, removing a member, admitting a late joiner.
- **Membership:** leave with an exit fee, be removed by vote, join mid-cycle with a sponsor.
- **Fees:** protocol and manager fees only on positive earnings, paid by claim.

## Tests

```sh
cd contracts && forge test        # 353 tests
pnpm -r test                      # contracts + shared + server end-to-end + web
pnpm lint && pnpm check:versions
```

- 353 contract tests pass: unit tests, the SPEC §4 worked example to the unit, property tests, and a stateful invariant suite across two circles that share members.
- Eight planted bugs are each caught by a named check.
- Slither reports no high or medium finding.
- The server test plays the whole tutorial as a user and checks every payout.

## Layout

| Path | What |
|---|---|
| `contracts/` | Solidity (Foundry): contracts, deploy script, tests |
| `packages/shared/` | Contract ABIs for the server and the app |
| `services/dev-api/` | Server: sign-up, test money, tutorial engine |
| `services/keeper/` | Starts circles and closes rounds for circles outside the tutorial |
| `apps/web/` | The web app (React, Vite, Tailwind) |
| `scripts/` | `dev.ts` (one-command start), `deploy.ts`, `verify.ts` |
| `Dockerfile` | The hosted demo: one container where every visitor gets a private test chain (`pnpm start:hosted`) |
| `docs/` | Product, spec, pages, test plan, build plan |
| `STATUS.md` | What is done and what is left |

## Honest limits

This is a proof of concept. The token and vaults are mocks, identity checks are mocked, and the tutorial runs on a local chain with test money. `STATUS.md` lists what is not built yet.
