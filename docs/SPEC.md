# Kuber: Technical Spec (v1, proof of concept)

This document is the build contract. Related docs:
- [PRD.md](PRD.md): the product
- [TECH_STACK.md](TECH_STACK.md): tools, the reasons for each, and keys
- [PAGES.md](PAGES.md): the UI
- [TEST_PLAN.md](TEST_PLAN.md)
- [BUILD_PLAN.md](BUILD_PLAN.md): build order

Development runs **locally on Anvil**. Fuji comes later.

## 1. Repo layout

```
kuber/
  contracts/                Foundry
    src/                    MockUSDC · MockAaveVault · MockLPVault · KuberRegistry · KuberFactory · KuberCircle
    src/lib/                only if size requires: Queue · Waterfall · Weights · Governance
    test/                   unit/ scenario/ fuzz/ invariant/ gas/ utils/
    script/Deploy.s.sol
  packages/shared/          generated ABIs + typed hooks (@wagmi/cli), addresses, zod schemas (mirror contract bounds), formatters, UI labels
  apps/web/                 React + Vite PWA (Privy, wagmi, Tailwind, Radix)
    src/app/                routes, layout, providers
    src/features/           onboarding · home · explore · circle · loans · votes · money · members · profile · dev
    src/components/         design-system primitives
    src/lib/                chain, auth, format
  services/dev-api/         Hono + SQLite: mock KYC, faucet, display names, dev time travel
  services/keeper/          settles epochs for every circle
  scripts/                  deploy.ts · seed.ts · demo.ts (30 wallets) · apy-sync.ts
  deployments/local.json
  docs/
```

**Boundaries:**
- Only `packages/shared` imports contract ABIs. The web app never holds admin keys.
- Services never hold user keys, because users sign with their Privy wallet.

## 2. Contracts

### 2.1 MockUSDC
- ERC20 `mUSDC`, 6 decimals.
- `mint` is callable only by minters: the vaults and the dev-api faucet signer.

There is no public faucet function. The faucet runs through dev-api with rate limits.

### 2.2 MockAaveVault and MockLPVault (ERC-4626 over MockUSDC)
- `totalAssets` grows by `assets × apyBps/10_000 × elapsed × speedup / 365 days`. `_accrue()` runs before every state change.
- Owner-only: `setApy(apyBps, sourceTs)` and `setSpeedup(x)`.
- **LP only:** `shock(int16 bps)`, owner-only, simulates price moves. It can lower the vault's value.

### 2.3 KuberRegistry
- **Mock KYC:**
  - `setVerified(addr, bool)` is owner-only. dev-api calls it after its own uniqueness check (one person, one address).
  - Only the flag is stored onchain.
- **History** per address. Circles the factory authorized are the only writers.
  - Member stats: `circlesJoined`, `circlesCompleted`, `loansTaken`, `repaidOnTime`, `lateInstallments`, `suspensions`, `kicks`.
  - Sponsor stats: `sponsoredCount`, `sponsoredCompleted`, `sponsoredSuspended`.
  - Manager stats: `managedEpochs`, `managedYieldBpsSum`.
- **Membership cap:** at most `MAX_ACTIVE_CIRCLES = 5` active memberships per person. Circles report joins, leaves, and finishes. Create, join, and apply revert at the cap. This also limits debts to 5.
- **Debt index:**
  - `addDebt(person, circle)` / `clearDebt(person, circle)` are called by circles and never revert (the cap guarantees room).
  - `debtCircles(person)` returns at most 5 circles.
  - `hasOpenDebt(person)`.
- **Protocol settings** (owner):
  - `treasury`
  - `protocolFeeBps`: default 1_000 (10% of positive yield), max 2_000
  - Gas reimbursement: `avaxPriceUsd6` (mock oracle), `gasPriceCap`, `maxReimbursePerEpoch`

### 2.4 KuberFactory
- `createCircle(name, FixedParams, RuleParams, address[] invites)` checks that the creator is verified, has no open debt, is under the membership cap, and invites at least 4 distinct addresses. Invitees are checked when they `join` (verified, no debt, under the cap), not at creation. It then:
  - clones the implementation and initializes it;
  - authorizes the circle in the registry;
  - emits `CircleCreated`.
- Views: `allCircles()`, `circleCount()`.

### 2.5 KuberCircle

#### Parameters
**Fixed at creation**
| Field | Demo | Real | Bounds |
|---|---|---|---|
| contribution | 100e6 | creator sets | > 0 |
| epochDuration | 60 s | 30 days | ≥ 30 s |
| lockBps (last part of each epoch) | 2_000 | 2_000 | 1_000–4_000 |
| startTime | now + 60 s | creator picks | > now |
| minSaveEpochs | 3 | 6 | **≥ 3** |
| totalEpochs | 7 | 12 | ≥ minSaveEpochs + 3, ≤ 60 |
| minMembers / maxMembers | 5 / 30 | 5 / 50 | **min ≥ 5**, max ≤ 50 |
| maxRepayEpochs | 3 | 3 | 1–3 |
| cooldownEpochs | 1 | 1 | ≤ 3 |

**Rules: starting values set at creation, then changed by vote, with bounds enforced**
| Field | Demo | Real | Bounds |
|---|---|---|---|
| ownLtvBps | 9_000 | 9_000 | 0–**10_000** |
| ownRateBps | 300 | 300 | 0–2_000 |
| perLoanMaxBps (share of the loan bucket) | 5_000 | 2_500 | 1_000–10_000 |
| fastLaneBps | 3_000 | 3_000 | 0–5_000 |
| alloc {loan, aave, lp, cash} | 500/5_000/3_500/1_000 | 2_000/4_000/3_000/1_000 | sum 10_000; loan ≤ 4_000; lp ≤ 5_000; cash ≥ 500 |
| penaltyBps (% of defaulted principal) | 1_000 | 1_000 | 0–5_000 |
| contribFineBps / installFineBps (per epoch late) | 100 / 300 | 100 / 300 | ≤ 1_000 / ≤ 2_000 |
| exitFeeBps | 300 | 300 | 0–2_000 |
| managerFeeBps (% of positive yield) | 0 | 0 | 0–1_000 |

**Constants**
- `MAX_MEMBERS 50`, `MIN_MEMBERS_FLOOR 5`, `MIN_SAVE_FLOOR 3`
- `SUSPEND_AT 3`
- `MAX_OFFERED_RATE 3_000`, `MAX_EXTRA 1_000`
- `AGREE_CAP = contribution`, `AGREE_RATE = offered/2`
- `MAX_VOUCHERS 10`, `MAX_AGREERS 10`
- `JOINS_PER_EPOCH 1`, `MAX_ACTIVE_CIRCLES 5` (per person, enforced by the registry)

#### States
- Circle: `Forming → Active → Ended`, or `Forming → Cancelled`.
- Member: `Active`, `Suspended`, `Left`, or `Kicked`. Only Active members vote and count toward thresholds.

#### Forming
- **Joining:** the creator invites addresses. Anyone verified and without open debt can call `requestToJoin()`, which the creator approves by inviting them. Invitees then `join()`.
- **Before start:** members can `leave()`, and the creator can `cancel()`.
- **Activation:** at `startTime`, anyone (in practice the keeper) calls `activate()`. If at least `minMembers` have joined, the circle becomes Active and epoch 1 starts at `startTime`. Otherwise it becomes Cancelled.
- **No money moves** while the circle is forming.

#### Epochs and windows
- `epoch(t) = (t − startTime) / epochDuration + 1`. Epochs advance by the clock; nobody "starts" them.
- Each epoch has two windows:
  - **OPEN** (the first `10_000 − lockBps` of the epoch): payments, loan requests, backing, unbacking, raising extra, proposals, votes, leave requests, join applications, sponsoring.
  - **LOCK** (the remainder): payments and votes only. Requests, backing, and proposals are frozen.
- **Settlement** of epoch `e` (`settle(maxMembers)`):
  - Anyone can call it once epoch `e` has ended and `e == settledEpoch + 1`. It's batched by a member cursor.
  - Member actions in epoch `e+1` (other than paying) wait until `e` is settled.
  - If several epochs were missed, settlement catches up one epoch at a time.

**Settlement steps for epoch `e`**
1. **Collect** (batched over Active members):
   - Auto-debit the contribution for `e` unless it was pre-paid. Otherwise record a miss.
   - Auto-debit the installment due in `e` plus any arrears. Otherwise add it to arrears.
   - Charge an installment fine on every unpaid installment for each epoch it's late.
   - Check the suspension trigger (run the waterfall if it fires).
   - **No weights accrue in this pass.** `completedEpochs` becomes `e` only after the pass has finished for every member, so batch order can't change anyone's weight (see Ledger).
2. **Apply** (once): passed proposals (rules, allocation, manager), leaves and kicks (exit values go to `claimable`, with the lien applied), admit the approved joiner.
3. **Fund** the loan queue (see Funding), and expire stale requests.
   - **Catch-up rule:** if settlement is behind (`epoch(now) > e + 1`), skip funding. Requests wait for the settlement of the latest ended epoch, so no loan starts with repayments already overdue.
4. **Rebalance** toward the allocation.
5. **Reimburse gas** to the caller and emit `EpochSettled(e)`.
6. If `e == totalEpochs`: suspend all unpaid loans, then **finalize**.

#### Ledger and time weights
Each member has:
- `savings`, `pledgedOut`, and `freeSavings = savings − pledgedOut`
- `paidEpochs`, `everBorrowed`
- `activeLoanId` / `pendingRequestId`, `cooldownUntil`
- `rewards`, `missedEpochs[]`, `weight`, `lastAccrual`

- **Weight** uses whole-epoch snapshots: for each completed epoch, it adds the member's savings as they stood after that epoch's collect pass finished for everyone.
  - It accrues lazily (`weight += savings × (completedEpochs − lastAccrual)`) before any change to savings.
  - Savings added during epoch `e` (pre-pay, catch-up, or collection) count from epoch `e` onward, in whole epochs.
- **Global accumulators** `W_active` (Active members) and `W_saver` (never borrowed and Active) accrue the same way, so their sums always match.
- **Running totals:** `S_total`, `S_saver`, `outstandingPrincipal`, `reservedClaims`, `totalRewardsOwed`, `saverPot`, `expenses`.
- **Invariant:** `savings ≥ pledgedOut`.

#### Payments
- **`payNow()`** works in OPEN or LOCK, **even while earlier settlements are still pending**. It pays the current epoch's contribution and any installment due, and settlement then skips them.
- **Advance allowance:** auto-debit needs an ERC-20 allowance set ahead of time.
  - The app asks once at join for `contribution × remaining epochs`.
  - It asks again at `claim` for the loan's total installments plus a 10% fine buffer.
  - The amount is shown in plain words. The user can revoke it any time; later debits then count as misses.
- **Auto-debit** requires `balanceOf ≥ amt && allowance ≥ amt`. If either is short, it records a miss and does not revert.
- **`catchUp(epoch)`** pays a missed contribution any time while the circle is Active.
  - It costs `contribution × (1 + contribFineBps × epochsLate/10_000)`. The fine goes to `saverPot`.
  - `savings` and `paidEpochs` go up, and the weight counts from the epoch it's paid in.
- **`payArrears()`** works any time, oldest first. Installment fines go to the loan's backers pro-rata by pledge, or to `saverPot` if the loan has no backers.

#### Loans
**Request.** `requestLoan(amount, repayEpochs, offeredRateBps, extraBps)` is allowed in OPEN when:
- the caller is Active, with `paidEpochs ≥ minSaveEpochs`;
- they have no active or pending loan, and `e > cooldownUntil`;
- `e + 1 + repayEpochs ≤ totalEpochs`.

**Locked terms.** These are snapshotted at request time: `ownLtv`, `ownRate`, `ownPart = min(amount, freeSavings × ownLtv)`, and `backedNeed = amount − ownPart`.

**Backing** (OPEN windows, while the request is pending):
- `vouch(id, amt)`: first loss, earns `offered`.
- `agree(id, amt)`: second loss, `amt ≤ AGREE_CAP`, earns `offered/2`.
- Limits: `amt ≤ freeSavings` and `Σ pledges ≤ backedNeed`.
- Who can't back: the borrower, and anyone with an active or pending loan.
- `unback(id)` withdraws backing during OPEN.
- The borrower can `raiseExtra` or `cancelRequest` during OPEN.

**Queue.** A request stays queued across epochs until it's funded, cancelled, or expired (expired means `e + 1 + repayEpochs > totalEpochs` at settlement; pledges are released).

**Funding** (settlement step 3). Definitions:
- `V = cash + aave.value + lp.value + outstandingPrincipal − (reservedClaims + totalRewardsOwed + saverPot)`
- `capacity = alloc.loan × V − outstandingPrincipal`
- A request is **eligible** if `Σ pledges == backedNeed`, `ownPart ≤ freeSavings × lockedLtv`, the borrower is Active, and `amount ≤ perLoanMaxBps × alloc.loan × V`.

Order of funding:
1. **Aged first:** eligible requests that have waited through 2 or more settlements are funded from **total** capacity, oldest first. Nobody waits forever behind fast-lane payers.
2. **Fast lane** (budget = `fastLaneBps × remaining capacity`): eligible requests with extra > 0, highest extra first, then oldest. Only fast-lane winners pay the extra, which goes to `saverPot`.
3. **Line lane** (budget = the rest plus whatever the fast lane didn't use): eligible requests, oldest first.
4. **Spill back:** if the line lane has budget left, run the remaining fast-lane candidates again.

Within a lane, a request that doesn't fit is skipped but keeps its place.

**When a loan is funded:**
- `interest = ownPart×ownRate + Σvouch×offered + Σagree×offered/2 (+ amount×extra if funded in the fast lane)`, each term divided by 10_000.
- `claimable[b] += amount`, `outstandingPrincipal += amount`.
- Installments are due in epochs `e+2 … e+1+repayEpochs`.
- On the first loan: `everBorrowed = true`, and the borrower's weight moves out of `W_saver`.
- `claim()` pays out using the withdraw order.

**Repayment.** Each installment is `(amount + interest)/repayEpochs`, with the remainder in the last one. It splits into:
- principal;
- the saver part (own interest + extra), which goes to `saverPot`;
- vouch interest, which goes to vouchers' `rewards`;
- agree interest, which goes to agreers' `rewards`.

**Early payoff.** `repayAll()` pays everything remaining. Interest is unchanged.

**When fully repaid:** pledges are released, the cooldown starts, and the registry is updated.

#### Suspension, waterfall, debt, lien, lockout
**Trigger:** 3 unpaid installments, **or** any installment unpaid for 3 epochs, **or** an unpaid balance at the end of the cycle.

**What happens:**
0. **Unclaimed proceeds first:** if part of the loan is still in the borrower's `claimable`, cancel it. `claimable`, `reservedClaims`, and `outstandingPrincipal` all drop by that amount, and it counts as repaid principal.
1. `O = amount − principalRepaid` (after step 0). Unpaid interest is forgiven.
2. **Borrower:** `s1 = min(freeSavings_b, O)`.
3. **Vouchers:** cover `min(Σvouch, O − s1)` pro-rata, with the last absorbing rounding.
4. **Agreers:** cover the remainder the same way.
5. **Group:** gets the remainder, which is 0 by construction. The contract asserts it.
6. **Penalty:** `P = penaltyBps × O`. It's paid from the borrower's leftover savings into `saverPot`, and anything unpaid is **added to debt**.
7. The member becomes **Suspended**: no pulls, no votes, no borrowing or backing, removed from the weights. The registry records the suspension, records `sponsoredSuspended` on their sponsor, and calls `addDebt`.
8. `debt` = per-backer losses + unpaid installment fines (owed to backers) + unpaid penalty (owed to `saverPot`).

**Recovery.** `repayDebt(amt)` is allowed while the circle is Active or Ended. Repayment order: agreers' losses, then vouchers' losses, then fines, then penalty.
- In the Ended state, backer amounts go to their `claimable`. The penalty portion goes to that loan's backers pro-rata, or to the treasury if it had no backers, because the savers' bonus has already been paid out. Debt and lockout stay until it's paid.
- When the debt is fully repaid: `clearDebt`, and if the circle is still Active the member is **reinstated** (history keeps the suspension).

**Lien.** Every payout to a person (exit, withdraw, rewards) first checks `registry.debtCircles(person)`. For each debt, it transfers tokens to that circle and calls `receiveLienPayment(person)` (only authorized circles can call this). The rest goes to the person.

**Lockout.** While `hasOpenDebt(person)` is true, that person can't create, be invited to, join, apply to, or sponsor in any circle.

**Why non-backers lose 0:** `ownLtv ≤ 100%`, so `ownPart ≤ freeSavings_b` at request time. A borrower's free savings can't fall during a loan (borrowers can't back anyone or be kicked, and seizures for their earlier pledges only touch the pledged part). So `O − s1 ≤ backedNeed = Σ pledges`. The fuzz tests check this.

#### Investing
- **Buckets:** loan (outstanding loans + an idle reserve held as cash, earning 0), Aave vault, LP vault, and cash (a buffer earning 0).
- **Rebalance** (settlement step 4): move each vault toward `alloc × V`. Circle cash never drops below `idleLoanReserve + cashBuffer + reservedClaims`.
- **Withdraw order** for payouts: cash, then Aave, then LP.
- Allocation changes take effect at settlement, before funding.

#### Membership changes
**Leave.** `requestLeave()` in OPEN. The member must be Active, with no loan or pending request and no pledges. The leave executes at settlement.
- `exitValue = savings + yieldShare + saverShare + rewards`, where:
  - `yieldPotNow = V − S_total`. If it's positive, `yieldShare = yieldPotNow × w / W_active`.
  - **If it's negative, the loss is shared by savings instead of time:** `yieldShare = yieldPotNow × savings / S_total`. No value goes below 0, and the totals always balance.
  - if `yieldShare` is positive, the protocol fee comes off first, then the manager fee;
  - `saverShare = saverPot × w / W_saver` (only for members who never borrowed).
- Payout = `exitValue − fee`, where `fee = exitValue × exitFeeBps / 10_000`, rounded up in favor of the pot. The fee goes to `saverPot`, and the payout goes to `claimable`, with the lien applied.
- The member can't rejoin the same circle this cycle.

**Kick.** Through a proposal. The target must have no loan, no pending request, and no pledges. They receive the same exit value with **no fee**.

**Join mid-cycle:**
1. `applyToJoin()`: the applicant must be verified, have no open debt, and not have left or been kicked this cycle.
2. `sponsor(applicant)`: the sponsor must be Active, with `paidEpochs ≥ minSaveEpochs`, no open debt, and no sponsorship yet this cycle. This auto-creates a Join proposal.
3. If it passes, the applicant is admitted at the next settlement. At most 1 join per epoch, and only while `e ≤ totalEpochs − 2`.
4. A new member votes and proposes only once `paidEpochs ≥ minSaveEpochs`.

**Public visibility.** All circle state is readable by anyone, so the Explore page shows every circle before you join.

#### Governance
- `propose(kind, data)` is allowed in OPEN by an Active member with `paidEpochs ≥ minSaveEpochs`. Kinds:
  - `Rule(field, value)`
  - `Allocation(4×bps)`: **only the manager can propose this while a manager is appointed**
  - `Manager(addr | 0)`: appoint, or fire with 0
  - `Kick(addr)`
  - `Join(addr)`: only via `sponsor`

  One open proposal per kind (per rule field). Bounds are checked when the proposal is made.
- `vote(id, yes)`: one per Active member, in OPEN or LOCK. The target of a kick can't vote on it.
- **Voting closes at the end of the epoch the proposal was created in.** Every proposal therefore gets at least the full LOCK window.
- **Thresholds** are measured against current Active members, and only votes from current Active members count:
  - Rule, Allocation, Manager: yes > 50%.
  - Kick: yes ≥ 2/3, excluding the target.
  - Join: yes > 50%, or at close, no < 1/3.
- **All effects apply at settlement.** Rule changes affect requests made after that.

#### Fees and expenses
- **Protocol fee:** `protocolFeeBps` of every positive yield share (at exits and at finalize) goes to `treasury`.
- **Manager fee:** `managerFeeBps` of positive yield (after the protocol fee) goes to the manager.
- **Gas reimbursement:**
  - A `settle` call is reimbursed only if it processes at least 10 members or finishes the settlement.
  - It pays `(gasUsed + overhead) × min(tx.gasprice, gasPriceCap) × avaxPriceUsd6 / 1e18` from circle cash.
  - The total per epoch is capped at `maxReimbursePerEpoch`, so tiny batches can't farm reimbursements.
  - It's tracked in `expenses`, which lowers `V`.

#### Share-out (finalize)
1. Redeem the vaults.
2. `yieldPot = cash − (reservedClaims + totalRewardsOwed + saverPot) − S_total`. This may be negative.
3. **Active member payout** = `savings + yieldShare + saverShare + rewards + claimable`, with the lien applied.
   - If `yieldPot > 0`: `yieldShare = yieldPot × w / W_active`, minus fees.
   - If `yieldPot < 0`: `yieldShare = yieldPot × savings / S_total`. The loss is shared by savings, so payouts can't go negative or exceed the assets.
4. **Suspended member payout** = leftover `savings` + `claimable`.
5. If `W_saver == 0`, the saver pot is merged into the yield pot.
6. Amounts are floored to 1 unit; dust stays. `withdraw()` pays each member once.
7. The registry records completions and the manager's stats.

#### Functions
| Function | Who / when |
|---|---|
| `invite`, `requestToJoin`, `join`, `leave`, `cancel`, `activate` | Forming |
| `settle(maxMembers)` | anyone, once an epoch has ended |
| `payNow`, `catchUp`, `payArrears`, `repayAll`, `repayDebt`, `receiveLienPayment` | member / authorized circle |
| `requestLoan`, `raiseExtra`, `cancelRequest` | borrower, OPEN |
| `vouch`, `agree`, `unback` | member, OPEN |
| `requestLeave`, `cancelLeave`, `applyToJoin`, `sponsor` | OPEN |
| `propose` (OPEN), `vote` (OPEN or LOCK) | Active member |
| `claim`, `withdraw` | member |
| `getCircleState()`, `getPublicSummary()`, `getLoan`, `getQueue`, `getProposal`, `exitValueOf` | views (public) |

#### Events
`Invited`, `JoinRequested`, `Joined`, `Activated`, `EpochSettled(e)`, `ContributionPaid`, `ContributionMissed`, `CaughtUp`, `LoanRequested`, `Backed(id, backer, tier, amt)`, `Unbacked`, `LoanFunded(id, lane)`, `RequestExpired`, `LoanClaimed`, `InstallmentPaid`, `InstallmentMissed`, `FineCharged`, `LoanRepaid(onTime)`, `MemberSuspended(id, O, fromBorrower, fromVouchers, fromAgreers, penaltyPaid, debt)`, `DebtRepaid`, `LienPaid`, `MemberReinstated`, `Rebalanced`, `ProposalCreated`, `Voted`, `ProposalPassed`, `ProposalApplied`, `ManagerChanged`, `LeaveRequested`, `MemberLeft`, `MemberKicked`, `JoinApplied`, `Sponsored`, `MemberAdmitted`, `GasReimbursed`, `Finalized`, `Withdrawn`.

## 3. Security practices

**Contracts**
- Checks-effects-interactions everywhere. `ReentrancyGuard` on every function that moves tokens. Pull payments (`claimable`) instead of pushes.
- `SafeERC20`. A single whitelisted token. Vault and circle addresses are fixed at init.
- Custom errors and explicit bounds on every parameter.
- No `tx.origin`, no `delegatecall` beyond the clone, and the implementation calls `_disableInitializers()`.
- All loops are bounded (50 members, 20 backers per loan, 5 debt circles, a queue of at most 50 requests).
- Rounding always favors the pot (floor payouts). Group loss is asserted to be 0.
- Circles have no owner. Registry and vault admin powers are explicitly mock-only and labelled in the UI.
- Fuzz and invariant suites (see the test plan). Slither and solhint in the check pipeline; no unresolved high or medium findings.

**Web and services**
- No secrets in the client (`VITE_*` values are public). Admin and keeper keys live only in `services/.env`, which is gitignored and has a `.env.example`.
- dev-api checks the Privy token on every request and validates input with zod.
  - The faucet is rate-limited.
  - KYC personal data is encrypted with AES-GCM at rest, with a unique hash of the ID number.
  - Dev routes are disabled outside dev mode.
- Before signing, the UI shows the simulated result (`simulateContract`) and a plain summary.
- Token approvals are bounded. The advance allowance covers remaining contributions and scheduled installments, plus 10% for fines. It's never unlimited, and the UI shows the number.
- The service worker caches only the static app shell, never API responses or personal data.
- A strict Content-Security-Policy, pinned dependencies with a lockfile, and `pnpm audit` in the checks.

## 4. Worked example (canonical test vector)

**Setup**
- 6 members (A to F), contribution 100, minSaveEpochs 3, totalEpochs 7.
- ownLtv 90%, ownRate 3%, perLoanMax 50%, alloc loan 40%, penalty 10%.
- **Protocol fee 0, gas reimbursement 0, no manager.**
- Everyone pre-pays at the start of each epoch, except D from epoch 4 on.
- Vault yield is 0 during the cycle, and 60 is credited at the end.
- Fines accrue unpaid (covered by unit tests).

| Epoch | Events |
|---|---|
| 1–3 | All pay, so savings are 300 each. The pot is 1,800 and the loan bucket 720. |
| 3 (OPEN) | A requests 350 over 2 epochs at an offered 8%: own 270 + backed 80 (B vouches 80). D requests 350 over 3 epochs at an offered 8%: own 270 + backed 80 (C vouches 30, E agrees 50). |
| settle 3 | Line lane: both are funded (700 ≤ 720; each ≤ 360). A owes 350 + 8.1 + 6.4 = 364.5, paid as 2 × 182.25. |
| 4 | D misses his contribution. Everyone else is at 400. |
| 5, 6 | A pays both installments: B's rewards reach 6.4 and the savers' pot 8.1. D is 1, then 2 behind. |
| settle 7 | D is 3 behind and is **suspended**. O = 350: D covers 300, C covers 30 (first), E covers 20 (second), group 0. The penalty of 35 is unpaid, so it goes to debt. D's debt is 50 to backers + 35 + fines. Then finalize. |
| End | cash 3,524.5. Liabilities 14.5. S_total 3,450. yieldPot 60. |

**Time weights** (sum of end-of-epoch savings):
- A, B, F: 2,800
- C: 2,770
- E: 2,780
- W_active = 13,950 and W_saver (B, C, E, F) = 11,150.

| Member | Payout | Net vs. what they paid in |
|---|---|---|
| A (borrower) | **712.043010** | −2.46 |
| B (vouched for A) | **720.477090** | +20.48 |
| C (vouched for D) | **683.926264** | −16.07 |
| D (suspended) | **0** | +50 (= C's + E's losses), and now owes a debt |
| E (agreed for D) | **693.976540** | −6.02 |
| F (pure saver) | **714.077090** | +14.08 |

## 5. Off-chain components

**dev-api** (Hono, local; every route needs a Privy token)
| Route | Does |
|---|---|
| `POST /session` | Verifies the token and returns the profile |
| `POST /kyc` | `{fullName, idNumber, dob}`: checks the ID hash is unique, stores the record encrypted, then calls `registry.setVerified(wallet)` |
| `POST /faucet` | Native gas (Anvil `setBalance`) + 10,000 mUSDC; once per hour per user |
| `GET/PUT /profile` | Unique display name |
| `GET /names?addrs=` | Public display names for the UI |
| `POST /dev/advance` | Dev only: Anvil time travel to the next epoch |

**keeper:** every few seconds, for each circle: `activate()` if due, then `settle(25)` until done.

**scripts**
- `deploy.ts` / `Deploy.s.sol`: deploys to Anvil and writes `deployments/local.json`.
- `seed.ts`: sample circles for Explore.
- `apy-sync.ts`: DefiLlama → `setApy`, with a snapshot as fallback.
- `demo.ts` runs PRD §7 in one of two modes:
  - **`--unattended`**: all 30 wallets, Alice included, are burner keys. Used for rehearsal and test S2.
  - **`--live --alice <address>`**: 29 bot wallets. At each of Alice's steps the script pauses until her transaction arrives from the PWA (her Privy wallet), then continues.

**web:** see [PAGES.md](PAGES.md).
- The web app uses **relative URLs**: `/rpc` for Anvil and `/api` for dev-api. The Vite dev server proxies both, so a single HTTPS tunnel serves a phone everything it needs.
- Auth modes: `privy` (default) and `dev` (a local burner key, used only by Playwright tests and offline dev, and never in a production build).

## 6. Assumptions (decided defaults; veto any before M2)
1. Every member of a circle pays the same contribution.
2. Rates are a flat amount per loan, and loan terms lock at request.
3. One loan or request per member at a time. Borrowers can't back anyone.
4. A suspended member is reinstated automatically after paying all debt.
5. Exit fee is 3% (the same as the own-part rate). Agreers pledge at most 1 contribution at half the rate. Joining needs 1 sponsor.
6. The idle loan reserve earns 0, by your choice.
7. Investment losses are shared by everyone in proportion to savings × time.
8. Protocol fee is 10% of positive yield. Settlement gas is reimbursed from the pot.
9. While a manager exists, only the manager proposes money-plan changes, and every change still needs a vote.
