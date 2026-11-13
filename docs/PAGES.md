# Kuber — Pages and UX Plan

A mobile-first PWA. Rules and states come from [SPEC.md](SPEC.md). Before building, the `gsd-ui-phase` step turns this file into a full UI contract (UI-SPEC.md).

## 1. UX principles (plain, friendly, not AI slop)
1. **Plain words, not finance jargon.** See the glossary in §5. The UI never shows "LTV", "bps", or "epoch".
2. **One main action per screen**, shown as the biggest button. Everything else is secondary.
3. **Tell people what happens before they sign.** Every transaction opens a sheet: "You pay 100 · Your savings become 400 · Due again in 29 days."
4. **Risk is spelled out in money.** "If Dave doesn't repay, you could lose up to 80." Not a percentage.
5. **Status uses words and color together**: 🟢 On track · 🟡 1 payment behind · 🟠 2 behind · 🔴 Paused. Color is never the only signal.
6. **Numbers have units and context**: "120 mUSDC · 4% of the pot".
7. **Progressive disclosure:** defaults are visible and advanced rules are folded away. Creating a circle works with defaults alone.
8. **Visual style:**
   - A calm, trustworthy palette, one accent color, real typography (a distinct heading font plus a clean body font), generous whitespace.
   - No gradient blobs, no glassmorphism, no emoji walls, no stock "AI" illustrations.
   - The design system lives in `DESIGN.md`, owned by **Impeccable**, and its hooks flag AI-template patterns during the build.
   - The Welcome page is polished with **Taste Skill**.
   - Review passes use `web-design-reviewer`, `design:design-critique`, and `design:ux-copy`.
9. **Accessible:** meets WCAG 2.2 AA, with 44 px touch targets, visible focus, and Radix primitives for dialogs, sheets, and tabs.
10. **Every screen has designed states:** loading (skeletons), empty (a short explanation plus an action), error (what happened plus a retry), and offline (cached view plus a banner).

## 2. Navigation
- **Bottom tab bar on mobile, sidebar on desktop:** Home · Explore · Activity · Profile.
- A circle opens a **Circle page** with tabs: Overview · Money · Loans · Votes · Members.
- Actions open as **bottom sheets** on mobile and dialogs on desktop: Pay, Borrow, Back a loan, Propose, Leave.

## 3. Pages

| # | Page | Purpose | Key content | Main action | Notes |
|---|---|---|---|---|---|
| P0 | **Install / splash** | PWA entry | App icon, name | "Install app" (if supported) | Shown once |
| P1 | **Welcome** | Explain in 5 seconds | "Save together. Borrow with your friends' backing." 3 short benefit lines | **Sign in** (Privy: email, Google, passkey) | The wallet is created silently on first login |
| P2 | **Onboarding** (3 steps) | Get ready to use the app | 1) Choose a display name 2) Verify identity (mock KYC: name, ID number, date of birth) 3) Get test money (faucet, dev only) + a 3-card "how it works" | **Continue** | KYC data goes to dev-api only; the chain stores just "verified" |
| P3 | **Home** | What needs me today | **"Due this round" card** (amount, time left, Pay now); my circles (name, round x/N, my savings, status); totals (saved · earned · borrowed · my backing at risk); alerts (votes waiting, backing requests, payments behind) | **Pay now** | The most-used screen |
| P4 | **Explore** | Find a circle | Search and filters (amount per round, size, status, risk level); circle cards (amount per round, members x/max, rounds left, mini money-plan donut, realized yield, default rate, manager) | Open a circle | Every circle is public before you join |
| P5 | **Circle page: header** | Context | Name, status (Forming / Round e of N / Ended), phase chip ("Open: requests and votes" or "Locked: settling soon"), countdown | Context-based: **Join / Apply / Pay / Withdraw** | The public view hides personal panels |
| P5a | Circle → **Overview** | Rules and my position | Rules in plain words; my savings, how much I can borrow, earned so far, "if I leave now I get X"; the round timeline | — | |
| P5b | Circle → **Money** | Where the pot is invested | Donut (target vs actual): loans / Aave / LP / cash, each with value and APY ("from Avalanche mainnet, updated …"); yield earned; savers' pot; fees; manager card with track record | Propose a new money plan (or the manager proposes) | |
| P5c | Circle → **Loans** | Borrow and back | My borrow limit; **queue** (fast lane / line, with my position); active loans (borrower, amount, backers, status); requests needing backing; my backing and its risk | **Borrow** | |
| P5d | Circle → **Votes** | Group decisions | Open proposals (plain-language effect, progress toward the threshold, time left, my vote); create a proposal; history | **Vote** | Votes close when the round ends |
| P5e | Circle → **Members** | Who's in | Member list with badges (⭐ saver, borrower, backer, 🟡🟠🔴, manager), on-time history, sponsor score; join applicants (sponsor, vote) | **Sponsor** (if eligible) | |
| P6 | **Create circle** (4-step wizard) | Start a group | 1) Basics: name, description, amount per round, round length preset, number of rounds, start date 2) People: invite by name or address (needs 4+) 3) Money plan: sliders with risk labels; loan rules folded under "Advanced" 4) Review in plain language | **Create circle** | Defaults work without changes |
| P7 | **Borrow** (sheet) | Request a loan | Amount slider showing "from your savings" vs "needs backing"; installments (1–3) with amounts and dates; rate offered to backers; optional fast-lane extra; total cost | **Request loan** → then "Share backing link" | A status view follows: backing progress → queue position → **Claim** |
| P8 | **Back a loan** (sheet) | Vouch or agree | Borrower profile and history, loan terms; choice: **Vouch** (takes loss first, earns X%) or **Agree** (takes loss second, max 1 contribution, earns X/2%); amount; a plain risk sentence | **Back this loan** | |
| P9 | **Pay** (sheet) | Pay what's due | Contribution, installment, overdue amounts, fines; "Pay all" or pick; catch-up list of missed rounds (fine shown) | **Pay** | Pre-pay any time during a round |
| P10 | **Propose** (sheet) | Start a vote | Pick a type: change a rule · new money plan · appoint or fire a manager · remove a member; a preview of the effect in words | **Create proposal** | Only during the Open window |
| P11 | **Leave circle** (sheet) | Exit | Exit value breakdown (savings + earnings − fee); what blocks leaving (a loan or backing); "You'll leave when this round ends" | **Leave** | |
| P12 | **Debt** | If paused | What I owe, to whom, the effect of paying (reinstated) | **Repay** | Shown instead of Home alerts while paused |
| P13 | **Share-out** | Circle ended | Final table, my payout breakdown | **Withdraw** | |
| P14 | **Activity** | What happened | A feed across my circles (payments, loans, votes, suspensions) | — | |
| P15 | **Profile** | Me | Name, verified badge, wallet address (copy), history across circles, sponsor score, manager record; export wallet (Privy), sign out | — | |
| P16 | **Dev panel** (dev builds only) | Local testing | "Skip to next round" (Anvil time travel), faucet, switch demo persona | — | Never in production builds |

## 4. Key flows (happy path)
1. **New user:** Welcome → Sign in → name → verify → test money → Home (empty state: "Explore circles or create one").
2. **Create:** Home → Create → 4 steps → circle page (Forming, countdown to the start date, invite status).
3. **Join a running circle:** Explore → circle page (public) → Apply → (a sponsor and a vote happen) → admitted next round → first payment.
4. **Borrow:** Loans tab → Borrow → share the backing link → friends open Back a loan → queue → funded at round end → Claim.
5. **Default (seen by a backer):** Activity: "Dave is 2 payments behind" → later "Dave paused: you covered 30" → Profile and history updated.
6. **Leave:** Overview → "If I leave now…" → Leave → paid at the end of the round.

## 5. Glossary (code term → UI word)
| Code | UI |
|---|---|
| epoch | round |
| OPEN / LOCK window | "Open for requests and votes" / "Locked: settling soon" |
| ownLtv, ownPart | "borrow limit", "from your savings" |
| backedNeed | "needs backing" |
| vouch / agree | "Vouch (first to cover)" / "Agree (second to cover)" |
| pledge | "your backing" |
| suspended | "paused" |
| saverPot | "savers' bonus" |
| allocation | "money plan" |
| exit value | "if you leave now" |
| settle | "round closing" |
