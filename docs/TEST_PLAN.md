# Kuber — Test Plan

This plan tests the rules in [SPEC.md](SPEC.md). A milestone in [BUILD_PLAN.md](BUILD_PLAN.md) is done only when its tests pass. Everything runs locally; there are no testnet dependencies.

## 1. Levels and tools
| Level | Tool | Location |
|---|---|---|
| Contract unit / scenario | Foundry `forge test` | `contracts/test/unit`, `scenario` |
| Fuzz / property | Foundry (1,000 runs locally; 10,000 in the full check) | `contracts/test/fuzz` |
| Invariant | Foundry stateful handler | `contracts/test/invariant` |
| Gas | `forge test --gas-report` | `contracts/test/gas` |
| Static analysis | Slither, solhint, `forge fmt --check` | `contracts/` |
| TypeScript unit | Vitest | `packages/shared`, `services/*`, `apps/web` (logic, hooks) |
| End-to-end (UI + chain) | Playwright against Anvil + dev-api + keeper (`VITE_AUTH_MODE=dev`) | `apps/web/e2e` |
| PWA / accessibility | Lighthouse CI (installable, a11y ≥ 95), axe in Playwright | `apps/web` |
| Demo | `node scripts/demo.ts` on Anvil | `scripts/` |

**Gates:**
- `KuberCircle` coverage ≥ 90% of lines.
- Properties (§9) and invariants (§10) pass.
- **S1 matches to the unit.**
- Slither: no unresolved high or medium findings.
- Playwright flows pass.

Anvil time travel (`vm.warp`, `evm_increaseTime`) drives epochs, so no test waits in real time.

## 2. Mocks, registry, factory
| ID | Case |
|---|---|
| T-TOK-1 | `mint` from a non-minter reverts |
| T-VLT-1 | the Aave vault grows 5% per year at 500 bps with speedup 1; speedup multiplies yield; deposit and withdraw accrue first |
| T-VLT-2 | LP `shock(−1000)` lowers value 10%; non-owner calls revert |
| T-REG-1 | `setVerified` is owner-only; history writes from an unauthorized caller revert |
| T-REG-2 | `addDebt` / `clearDebt` / `hasOpenDebt` never revert; membership cap: a 6th active circle (create, join, or apply) reverts |
| T-REG-3 | protocol fee above 20% reverts; treasury and gas settings are owner-only |
| T-FAC-1 | create reverts with fewer than 4 distinct invitees, an unverified or indebted creator, a creator at the membership cap, or out-of-bounds params (invitees are checked at join; see T-FRM-1) |
| T-FAC-2 | the created clone is authorized and listed; the implementation can't be initialized |

## 3. Forming, epochs, windows
| ID | Case |
|---|---|
| T-FRM-1 | only invited, verified, debt-free addresses join; `requestToJoin` emits an event and the creator can invite |
| T-FRM-2 | `activate` before `startTime` reverts; at or after `startTime` with ≥ 5 members → Active, with < 5 → Cancelled |
| T-FRM-3 | no tokens move while forming; `cancel` is creator-only |
| T-EP-1 | `epoch(t)` maps time correctly; OPEN and LOCK boundaries follow `lockBps` |
| T-EP-2 | requests, backing, and proposals revert during LOCK; pay and vote work during LOCK |
| T-EP-3 | `settle` before the epoch ends reverts; skipped epochs catch up one per call; no loans are funded during catch-up, and queued requests are funded at the latest settlement with a fresh repayment schedule |
| T-EP-4 | actions in epoch e+1 (other than paying) revert until e is settled |
| T-EP-5 | batched settle over 2 calls gives the same result as 1 call **for any member order**, including a default whose backers are processed before the borrower (same weights); actions other than paying revert mid-settle |
| T-EP-6 | the final settle finalizes |

## 4. Payments
| ID | Case |
|---|---|
| T-PAY-1 | `payNow` works in OPEN or LOCK, even while earlier settlements are pending; settle doesn't pull twice |
| T-PAY-2 | auto-debit succeeds with enough balance and allowance; a shortfall records a miss without reverting |
| T-PAY-3 | `catchUp` charges 1% per epoch late to the savers' bonus; savings and paidEpochs increase; a second catch-up of the same epoch reverts |
| T-PAY-4 | installment arrears add 3% per epoch late; `payArrears` pays oldest first; fines go to backers pro-rata, or to the savers' bonus if there are no backers |
| T-PAY-5 | with the advance allowance set at join, every future contribution auto-debits; revoking the allowance turns later debits into misses |

## 5. Loans, backing, queue
| ID | Case |
|---|---|
| T-LN-1 | request blocked by paidEpochs < minSave, an existing loan or request, cooldown, or a repay window past the end |
| T-LN-2 | terms lock: a rule change applied before funding doesn't alter the request |
| T-LN-3 | ownPart = min(amount, 90% of free savings); backedNeed = the rest |
| T-BK-1 | the borrower or someone with a loan can't back; agree > 1 contribution reverts; over-pledging reverts; pledge > free savings reverts |
| T-BK-2 | `unback` during OPEN releases the pledge; during LOCK it reverts |
| T-Q-1 | an unfunded request stays queued into the next epoch with its age kept |
| T-Q-2 | fast lane: 30% of capacity, highest extra first; only fast-lane winners pay the extra |
| T-Q-3 | line lane: oldest first; unused fast budget spills to the line, and leftover line budget spills back |
| T-Q-4 | a request too big for what's left is skipped and keeps its place |
| T-Q-5 | a request whose repay window passes the end of the cycle expires and its pledges are released |
| T-Q-6 | per-loan max and bucket capacity are enforced |
| T-Q-7 | a backed request that fits total capacity but not the line budget is funded once it has waited 2 settlements, ahead of the fast lane |
| T-RP-1 | the installment split is exact (principal, saver part, vouch part, agree part) |
| T-RP-2 | `repayAll` clears the loan, releases pledges, and starts the cooldown; on-time repayment updates the registry |

## 6. Defaults, debt, lien, lockout
| ID | Case |
|---|---|
| T-DF-1 | miss 1 then pay 2: OK. Miss 2 then pay 1: OK. 3 unpaid: paused. One installment unpaid for 3 epochs: paused. Unpaid at the end: paused |
| T-DF-2 | unclaimed loan proceeds are cancelled first; then the waterfall is borrower, vouchers, agreers; group loss is 0 (asserted); the borrower can't claim afterwards |
| T-DF-3 | penalty = 10% × O; paid from leftover savings, and the unpaid part goes to debt |
| T-DF-4 | a paused member isn't pulled, can't vote, borrow, or back, and is out of the weights; the registry records the pause, the sponsor's `sponsoredSuspended`, and `addDebt` |
| T-DF-5 | `repayDebt` order is agreers, vouchers, fines, then penalty; full repayment reinstates (Active) and clears the debt; in the Ended state backer amounts go to `claimable` and the penalty goes to the backers pro-rata (the treasury if there were none); the lockout stays until the debt is paid |
| T-DF-6 | **lien**: an exit or withdraw from circle X first repays the person's debt in circle Y |
| T-DF-7 | **lockout**: someone with open debt can't create, be invited, join, apply, or sponsor |

## 7. Investing, membership, governance, fees, share-out
| ID | Case |
|---|---|
| T-INV-1 | after settle, vault values match the targets (±1 unit); cash stays ≥ idle loan reserve + buffer + claims |
| T-INV-2 | payouts withdraw from cash, then Aave, then LP; an allocation outside the bounds reverts |
| T-INV-3 | an allocation change applies at settle, **before** funding (the demo depends on this) |
| T-MEM-1 | leave blocked by a loan, request, or pledges; executes at settle; payout = exit value − 3%; can't rejoin this cycle |
| T-MEM-2 | after an LP shock the exit value drops below savings, the loss is shared by savings (not time), and it never goes below 0; the 3% exit fee is rounded up |
| T-MEM-3 | apply → sponsor → Join proposal → admitted at settle; a second join in the same epoch waits; a new member can't vote until minSave |
| T-MEM-4 | a sponsor without enough paidEpochs, who already sponsored, or with debt reverts |
| T-GOV-1 | proposals only in OPEN; one open per kind; bounds checked; voting closes at the end of the epoch |
| T-GOV-2 | > 50% passes and exactly 50% fails; kick needs ≥ 2/3 with the target excluded; kick of someone with a loan or pledges reverts; join passes by lazy consensus |
| T-GOV-3 | only votes from current Active members count |
| T-GOV-4 | manager: appoint and fire by vote; while a manager exists, an Allocation proposal from a non-manager reverts; the manager's proposal still needs > 50% |
| T-FEE-1 | the protocol fee applies only to positive yield shares, at exit and finalize, and goes to the treasury |
| T-FEE-2 | the manager fee comes after the protocol fee; the registry records the manager's stats |
| T-FEE-3 | gas reimbursement is paid only for calls that process ≥ 10 members or finish the settlement; the per-epoch cap holds even with many tiny calls; `expenses` lowers V |
| T-END-1 | payout formula; a paused member gets only leftover savings + claimable |
| T-END-2 | a negative yieldPot is shared pro-rata by savings; payouts sum to exactly the assets (± dust) and none is negative; when W_saver = 0 the saver bonus merges into yield |
| T-END-3 | a second `withdraw` reverts; dust stays |

## 8. Off-chain
| ID | Case |
|---|---|
| T-API-1 | every route without a valid Privy token (or dev token in dev mode) returns 401 |
| T-API-2 | KYC: the ID hash is unique (a second account with the same ID is rejected); the record is encrypted at rest; `setVerified` is called |
| T-API-3 | faucet: once per hour per user; dev routes return 404 outside dev mode |
| T-API-4 | display names are unique; `/names` returns only public fields |
| T-KPR-1 | the keeper activates due circles and settles every circle until caught up; it recovers after downtime |
| T-SHR-1 | zod schemas in `packages/shared` match the contract bounds (generated constants) |
| T-E2E-1 | onboarding: sign in (dev mode), set a name, verify, faucet, see the Home empty state |
| T-E2E-2 | create a circle with 4 invitees; it auto-activates at the start date (via time travel) |
| T-E2E-3 | Explore shows a circle's public page before joining; apply → sponsor → vote → admitted |
| T-E2E-4 | pay, borrow, back (vouch and agree), then the queue → claim flow |
| T-E2E-5 | propose a money plan → vote → applied at settle; the donut updates |
| T-E2E-6 | default path: badges go 🟡 → 🟠 → 🔴; debt shows on the profile; lockout is shown |
| T-E2E-7 | leave → paid at round end; share-out → withdraw |
| T-PWA-1 | the manifest and service worker are valid and the app is installable; the offline shell shows a banner; API responses are never cached |
| T-A11Y-1 | axe finds no serious violations on P1–P15; keyboard navigation works for sheets and tabs |

## 9. Scenarios and properties
| ID | Case |
|---|---|
| **S1** | **SPEC §4 worked example matches to the unit** |
| S2 | PRD §7 demo with 30 members: the final state matches the narration |
| S3 | a 50-member full cycle with random behavior finalizes |
| **P1** | **A non-backer who stays to the end is paid at least their contributions whenever the net investment result (yield − gas expenses − fees) is ≥ 0**, across random sequences of borrowing, defaults, votes, kicks, leaves, joins, and manager actions |
| P2 | Σ payouts + exits + fees + expenses ≤ all inflows (contributions + interest + fines + yield) |
| P3 | kicking a member doesn't change that member's exit value (other than the fee rules) |
| P4 | group loss in the waterfall is always 0 |
| P5 | two identical members get identical payouts |
| P6 | a fully backed request with no extra, whose amount stays ≤ total capacity, is funded within 3 settlements (no starvation) |

## 10. Invariants
- I1: `savings ≥ pledgedOut`.
- I2: running totals equal per-member sums.
- I3: `reservedClaims == Σ claimable`.
- I4: `outstandingPrincipal == Σ` unpaid principal.
- I5: cash + vaults + loans ≥ non-member liabilities (claims + rewards owed + savers' bonus). Member savings are the residual claim and can be haircut after an investment loss.
- I6: the allocation sums to 10,000 and stays within bounds.
- I7: the registry debt index matches each circle's debts.

**Gas:**
- G1: 50 members with 20 loans: each `settle(25)` call < 8M gas.
- G2: queue funding with 50 requests < 3M gas.
- G3: a 50-member vote tally < 1M gas.

## 11. Pre-demo checklist
- [ ] `demo.ts --unattended` completes 7 rounds twice in a row; `demo.ts --live` works with Alice's Privy wallet
- [ ] A fresh Privy sign-up reaches the verified Home screen in under 1 minute
- [ ] Installed PWA on a phone through one HTTPS tunnel (app, `/rpc`, and `/api` proxied): the full flow works
- [ ] The UI review (`web-design-reviewer`, `design:design-critique`) has no open high-priority issues
- [ ] A backup recording exists
