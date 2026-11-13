# Kuber — Product Requirements (v1, proof of concept)

**One line:** A savings-circle app (installable PWA). You sign in with email, Google, or a passkey, and a wallet is created for you automatically. Groups of 5–50 verified people save every round and vote on where the money is invested. Members borrow up to 90% of their own savings, plus more if friends back them. **If you don't back anyone, nobody else's default can cost you your savings.**

**Proof-of-concept scope:**
- Everything is mocked: token, Aave, LP, and KYC. Yield numbers come from Avalanche mainnet.
- Runs locally on Anvil; Fuji comes later.
- No legal or compliance work.

**Related docs:**
- [SPEC.md](SPEC.md): rules and contracts
- [TECH_STACK.md](TECH_STACK.md): tools, reasons, keys
- [PAGES.md](PAGES.md): screens
- [TEST_PLAN.md](TEST_PLAN.md)
- [BUILD_PLAN.md](BUILD_PLAN.md)

## 1. Problem
Savings groups (India's SHGs, chits) run on trust and paper:
- Organizers can run off with the money.
- Payments get disputed.
- Money sits idle.
- One default hurts everyone.

Onchain lending only lets you borrow less than you deposit, so it gives no credit to someone who needs a bit more.

## 2. How it works
1. **Sign up.** Email, Google, or passkey, and a wallet is created silently. You verify your identity (mocked), so each person has one account.
2. **Find or create a circle.** Every circle is public: you can see its rules, money plan, members, and track record before joining. Creating one needs you plus at least 4 others, and it starts automatically on the start date.
3. **Save every round.** Pay whenever you like during the round. Anything unpaid is auto-debited when the round closes. Missed payments can be caught up later, with a fine.
4. **Money plan.** The group votes on how the pot is split: loan reserve (idle until lent), Aave, LP, cash. An optional **fund manager** proposes changes, and every change still goes to a vote.
5. **Borrow.** After saving at least 3 rounds (6 in real circles):
   - up to 90% of your own savings (the interest goes to the savers' bonus);
   - more if **vouchers** (cover losses first, earn your offered rate) and **agreers** (cover second, earn half) back you.
   - Requests wait in a queue: a **fast lane** for people paying extra, and a **line** for everyone else in order, so nobody waits forever.
6. **Repay.** Pay by installment or all at once. You can fall up to 2 payments behind (with fines). At 3 behind you're **paused**.
7. **Default.** Your savings pay first, then vouchers, then agreers, and everyone else loses 0. A penalty and the unpaid amounts become **debt that follows you**:
   - any money you'd get from any Kuber circle repays it first;
   - you can't join new circles until it's paid;
   - paying it back gets your backers their money back and reinstates you.
8. **Vote.** Each round is OPEN (requests, votes) and then LOCKED (settling). Proposals get the whole rest of the round to be voted on. Every change happens when the round closes.
9. **Leave or finish.** Leave at the end of any round if you have no loan or backing. You get your savings plus earnings, minus a small early-exit fee. At the end of the cycle everyone is paid out.

## 3. Who gets what
| Role | Gets | Risks |
|---|---|---|
| Saver (never borrows) | Savings + investment yield + **savers' bonus** (own-part interest, fast-lane extras, fines, fees, penalties) | Shared investment risk only |
| Borrower | Early access to their own savings + credit from backers; earns yield | Interest; fines, pause, and debt if they default |
| Voucher | Offered rate on their pledge, plus yield (the pledge never leaves the pot) | First to cover, up to their pledge |
| Agreer | Half the offered rate | Second to cover, up to their pledge (max 1 contribution) |
| Fund manager (optional) | Manager fee (voted, from positive yield), plus a public track record | Can be fired by vote |
| Kuber (protocol) | 10% of positive investment yield | Runs the keeper |

Earnings are shared by **savings × time**.

## 4. Goals and non-goals
**Goals**
- G1. Nobody can move pooled money except by the rules.
- G2. Non-backers never lose savings to a default; the contract enforces this.
- G3. Credit beyond your own savings comes only from people who chose to back you.
- G4. The group controls its money plan within safe limits.
- G5. No vote can take a member's money.
- G6. Easy enough for non-crypto users: no seed phrases, plain words.
- G7. Works with up to 50 members.
- G8. The local demo runs end to end, reliably.

**Non-goals:** real funds or integrations, real KYC, compliance, Fuji or mainnet deployment (later), gasless smart accounts (later), push notifications (P1), privacy features (later).

## 5. Features
**P0**
| # | Feature |
|---|---|
| F1 | Accounts: Privy sign-in with an auto-created embedded wallet; display name; mock KYC; dev faucet |
| F2 | PWA: installable, offline app shell, mobile-first |
| F3 | Explore: all circles visible before joining |
| F4 | Create a circle (min 5, scheduled auto-start), invite-only forming |
| F5 | Epochs with OPEN/LOCK windows and permissionless settlement (Kuber keeper) |
| F6 | Payments: pre-pay, auto-debit, catch-up with fines |
| F7 | Money plan: votable split across loan / Aave / LP / cash, rebalanced each round, mainnet APYs |
| F8 | Loans: own + backed parts, offered rate, queue (fast lane + line), early payoff, cooldown |
| F9 | Backing: vouch (first loss) and agree (second loss) |
| F10 | Defaults: pause at 3 behind, waterfall, penalty → debt, cross-circle lien, lockout, recovery and reinstatement |
| F11 | Membership: leave at round end (exit fee), kick by vote, mid-cycle join (sponsor + vote), sponsor score |
| F12 | Governance: rules, money plan, fund manager (appoint/fire), kicks, joins |
| F13 | Fees: protocol fee on positive yield; settlement gas reimbursed from the pot |
| F14 | Share-out and withdraw; history across circles |
| F15 | Scripts: deploy, seed, demo (30 wallets), APY sync |

**P1:** LP "market dip" demo button · push reminders · gasless transactions · Fuji deployment.

## 6. Rules
| Rule | Demo | Real | Changed by |
|---|---|---|---|
| Contribution | 100 mUSDC | creator | fixed |
| Round length (OPEN / LOCK split) | 60 s (48 / 12) | 30 days (24 / 6) | fixed |
| Start | automatic at the start date if 5+ members, otherwise cancelled | same | fixed |
| Minimum saving rounds before borrowing | 3 | 6 | fixed (never fewer than 3) |
| Total rounds | 7 | 12 | fixed |
| Group size | 30 | 5–50 | fixed |
| Own borrow limit | 90% of free savings | 90% | vote (never above 100%) |
| Own-part interest → savers' bonus | 3% per loan | 3% | vote (0 allowed) |
| Backers' rate | borrower offers 0–30% | same | borrower |
| Agreer | half the rate, max 1 contribution | same | fixed |
| Max per loan | 50% of the loan reserve | 25% | vote |
| Fast-lane share | 30% | 30% | vote (max 50%) |
| Money plan (loan / Aave / LP / cash) | 5 / 50 / 35 / 10 | 20 / 40 / 30 / 10 | vote: loan ≤ 40%, LP ≤ 50%, cash ≥ 5% |
| Late fines, contribution / installment | 1% / 3% per round late | same | vote |
| Pause | 3 payments unpaid, or one unpaid for 3 rounds | same | fixed |
| Penalty | 10% of the defaulted amount (unpaid part becomes debt) | same | vote |
| Early-exit fee | 3% | 3% | vote |
| Cooldown after repaying | 1 round | 1 | fixed |
| Manager fee | 0% of positive yield | 0% | vote (max 10%) |
| Protocol fee | 10% of positive yield | same | Kuber (max 20%) |
| Votes | rules / money plan / manager > 50%; kick ≥ two-thirds; join > 50% yes, or < one-third no at close | same | — |

## 7. Demo script (about 7 minutes, local, 30 wallets)
Run it with `demo.ts --live --alice <address>`: the bots act automatically, and the script waits for Alice's taps in the PWA. Rehearse with `demo.ts --unattended`.

Personas:
- **Alice:** presenter, using the PWA.
- **Bob:** vouches for Alice.
- **Dave:** defaults.
- **Frank:** vouches for Dave.
- **Erin:** agrees for Dave.
- **Carol:** a pure saver.
- 24 bots.

| Round | What the audience sees |
|---|---|
| 0 | Alice signs in with email; a wallet is created and she's verified. She opens the circle from Explore. |
| 1–2 | 30 members saving. The money plan donut shows 5 / 50 / 35 / 10 with live mainnet APYs. |
| 3 | Alice pre-pays round 3 (she needs 3 paid rounds to borrow or propose). Alice requests 350: 270 from her own savings, plus Bob vouches 80 at her offered 8%. Dave requests 350: Frank vouches 30, Erin agrees 50. The loan reserve is only 450, too small for both. Alice proposes loans 10% / Aave 45%. 16 of 30 vote yes. When the round closes, the new plan applies and both loans are funded. |
| 4 | Alice claims her loan. Dave's contribution is missed. |
| 5–6 | Alice repays and Bob earns 6.4. Dave goes 🟡 1 behind, then 🟠 2 behind, with fines adding up. |
| 7 | Dave is 🔴 paused. His 300 savings pay first, Frank loses 30, Erin loses 20, and **the other 27 lose 0**. Dave's profile shows his debt and that he's locked out of new circles. Then the share-out table. |

## 8. Success criteria
- Every P0 feature works locally: sign-up, then join, then borrow, all in the PWA.
- The demo passes twice in a row.
- Contract line coverage is at least 90%. Property P1 ("non-backers never lose savings to a default") passes fuzzing. Playwright end-to-end flows pass.
- The PWA is installable (Lighthouse installable check passes), and the main screens meet WCAG 2.2 AA.

## 9. Known risks we accept
- Defaulters keep the backed part. Backers chose that risk, and the debt follows the defaulter.
- Unpaid interest on a defaulted loan is lost.
- Investment losses are shared by everyone. The "can't lose" promise covers **defaults only**.
- A member could time an exit to an LP high.
- Off-chain vote buying is possible; damage is bounded.
- Founding members can be friends of the creator who vote as a block, but they can't take money, and others can leave.
- Data is public; privacy comes later.
- Mock admin powers exist; there are no upgrades.
- No credit on day one: you must save at least 3 rounds.

## 10. Decision log
| Decision | Why |
|---|---|
| Savings circle, not an auction chit | A chit's round-1 winner can't be collateralised without killing the credit |
| Own limit ≤ 100% | Non-backers can never lose savings to a default |
| Vouch + agree tiers | Lets careful members help with less risk |
| Borrower offers the backers' rate | Only backers earn it, so only they need to agree |
| Two-lane queue | Paying extra helps, but the line lane guarantees nobody starves |
| Penalty → debt, lien, lockout | A default follows the person, at no cost to honest users |
| Epochs with OPEN/LOCK windows | Predictable: changes happen only when a round closes, voting always has time, no last-second sniping |
| Fund manager proposes, the group votes | Gives the group expertise without giving up control |
| Public circles | Join with full information |
| Privy embedded wallets | Normal sign-in; no seed phrases |
| PWA | Installable on phones with no app store |
| Local Anvil first | Fast iteration and time travel for epoch tests |
| Leave without a vote; no kicking members with loans | Nobody's money can be trapped; no forced-liquidation gaps |
| Time-weighted sharing | Fair when people join and leave at different times |
