# Kuber — Build Plan

This plan sets the build order for [SPEC.md](SPEC.md), [PAGES.md](PAGES.md), and [TECH_STACK.md](TECH_STACK.md). A milestone is done only when its tests in [TEST_PLAN.md](TEST_PLAN.md) pass. **Everything runs locally on Anvil; Fuji comes later.**

## 1. How we build

### Workflow (GSD)
1. `gsd-ingest-docs`: turn `docs/` into `.planning/`, with the milestones below as phases.
2. `gsd-settings`: set the model profile to match the tiers in the next table. GSD agents must not default to Fable.
3. For each milestone: `gsd-plan-phase` → `gsd-execute-phase` → run the tests → `gsd-verify-work`.
4. Security: run `gsd-secure-phase` after M7, and `gsd-code-review` on contracts after M5 and M7.
5. UI: run `gsd-ui-phase` (`PAGES.md` → `UI-SPEC.md`) **before** M9, and `gsd-ui-review` after M9.

### Skills
| Skill | When |
|---|---|
| `ponytail` | Every coding task: the smallest change that fully solves it, no extra abstractions |
| OpenZeppelin `setup-solidity-contracts`, `develop-secure-contracts` (official) | M0–M7 contract work |
| Privy skill + Privy docs MCP (official) | M8–M9 auth and wallet work |
| Avalanche Builder Hub MCP (official) | Chain config and EVM questions |
| **Impeccable** (`/impeccable init`, `document`, `typeset`, `polish`, hooks on) | M9–M10: owns the app design system (DESIGN.md) and the anti-template checks |
| Anthropic **`frontend-design`** | M9 start: visual direction for UI-SPEC |
| **Taste Skill** (`design-taste-frontend`) | M10: Welcome page (P1) only |
| `web-design-reviewer`, `design:design-critique`, `design:ux-copy`, `accessibility`, `responsive-design`, `no-ai-slop` | M9–M10 review passes |
| `dataviz` | The money-plan donut and progress bars |
| **Codex `image_gen`** (gpt-image-2; tested and working) | PWA icon set, onboarding illustrations, empty-state art. Run `codex exec -s workspace-write` with a precise prompt, review the result, then commit the files to `apps/web/public/`. |
| `caveman` | Terse internal status notes and subagent briefs. Not for explanations to the user. |
| `check-compiler-errors`, `deslop`, `simplify` | Before closing each milestone |
| `security-review` | Before declaring the build done |

### Subagent model tiers (never default to Fable)
| Tier | Use for |
|---|---|
| **opus** (default for subagents, set in `~/.claude/settings.json`) | **All coding:** contracts, tests, React screens, services, scripts, the accounting and waterfall math, fuzz and invariant design, security review, debugging |
| **haiku** | Only trivial, purely mechanical chores: search, file listing, renames, formatting |
| **fable** | Main session only. It plans, decides which model each task needs, and reviews the results. |
| *sonnet* | Not used |

The main session picks the model for each task and sets `model` explicitly on every Agent call. When unsure, it uses opus.

### Git
- Work on a branch (`build`), never on `main` or `master`.
- Commit when a milestone's tests pass, with a message that names the milestone.
- Never commit `.env` files.

## 2. Milestones

| # | Milestone | Main tasks | Done when |
|---|---|---|---|
| M0 | **Scaffold** | Install the exact versions in TECH_STACK §3: Foundry v1.9.0, Slither 0.11.6, `foundry.toml` with solc 0.8.38 and `evm_version = "cancun"`. Set up the pnpm 12.18 workspace (`contracts`, `packages/shared`, `apps/web`, `services/*`, `scripts`), `.nvmrc` (26), OpenZeppelin 5.6.1, `@wagmi/cli` codegen, Biome, `.env.example` files. Add `pnpm dev`, which starts Anvil and deploys. dev-api, keeper, and web start as stubs; the fully integrated command is gated at M9. Use the OpenZeppelin `setup-solidity-contracts` skill. | `forge build`, `pnpm -r build`, and `pnpm -r test` pass; versions match TECH_STACK §3 |
| M1 | **Mocks + registry** | MockUSDC, both vaults, KuberRegistry (KYC, history, debt index, protocol settings) | T-TOK, T-VLT, T-REG |
| M2 | **Circle core** | Factory and clones; forming and activation; epochs, windows, batched settle; payments; time weights; share-out without loans | T-FAC, T-FRM, T-EP (except the funding part of T-EP-3), T-PAY-1–3 and T-PAY-5, T-END-1 (Active members only), T-END-3; a 50-member savings-only cycle. **Also define the shared `Loan`/`Backing` structs, events, and ledger hooks now**, so M4–M5 don't cause rework. |
| M3 | **Investing** | Allocation, rebalance, withdraw order, negative yield | T-INV-1, T-INV-2, T-END-2 (T-INV-3 needs loans and governance, so it moves to M6) |
| M4 | **Loans + queue** | Locked terms, own/backed split, two-lane queue, claim, installments, arrears, early payoff, cooldown | T-LN, T-Q, T-RP, and T-PAY-4 for **own-part loans only** (backed splits are tested in M5) |
| M5 | **Backing + defaults** | Vouch and agree; the pause trigger; waterfall; penalty → debt; recovery; lien; lockout | T-BK, T-DF, T-RP-1 with backers, T-END-1 for suspended members; **S1 passes** |
| M6 | **Governance + membership** | Proposals (rule, allocation, manager, kick, join), thresholds, leave, kick, mid-cycle join, sponsor score | T-GOV, T-MEM, T-INV-3 |
| M7 | **Fees + hardening** | Protocol and manager fees; gas reimbursement; P1–P6; I1–I7; G1–G3; S3; Slither clean; coverage ≥ 90% | T-FEE; TEST_PLAN §9–10 |
| M8 | **Services + scripts** | dev-api (Privy check, KYC, faucet, names, dev time travel); keeper; deploy, seed, apy-sync, and demo scripts | T-API, T-KPR, T-SHR; S2 via `demo.ts --unattended` |
| M9 | **Web PWA** | Providers (Privy, wagmi, Query); design system (tokens, Radix primitives); P0–P16 from PAGES.md; PWA manifest and service worker; dev auth mode | the flows in PAGES §4 are usable; the integrated `pnpm dev` starts everything; `demo.ts --live` works with a Privy wallet; app icons and illustrations are generated (Codex `image_gen`) |
| M10 | **E2E + polish** | Playwright T-E2E/T-PWA/T-A11Y; Lighthouse; UI review and fixes; a demo rehearsal ×2; a backup recording | TEST_PLAN §11 checklist complete |
| M11 | *(later)* Fuji | Deployer key, deploy, verify, a public demo URL | — |

## 3. Order

```
M0 → M1 → M2 ─┬→ M3 ─┐
              └→ M4 → M5 → M6 → M7 → M8 → M9 → M10
```

- M3 and M4 can run in parallel; for example, two opus subagents in separate worktrees.
- M9 UI work can start after M8's deploy script exists: build screens against Anvil, using the generated hooks from `packages/shared`.

## 4. Keys timeline (details in TECH_STACK §5)
| When | You need |
|---|---|
| M0–M7 | Nothing external. Anvil's default keys only. |
| M8 | `KYC_ENCRYPTION_KEY` (generate it locally) |
| M9 | **Privy App ID and verification key** (dashboard.privy.io). Enable email, Google, and passkey login; embedded wallets "create on login"; allowed origin `http://localhost:5173`; custom chain Anvil 31337 |
| M10 (phone demo) | An HTTPS tunnel URL added to Privy's allowed origins |
| M11 | Fuji deployer key and an explorer API key |

## 5. Cut lines (if time is short, drop from the top of this list first)
| Order | Cut | Fallback |
|---|---|---|
| 1 | Fund manager | Everyone proposes money-plan changes |
| 2 | Mid-cycle join + sponsor score | Members join only while forming |
| 3 | Cross-circle lien | The debt is recorded and blocks new circles only |
| 4 | Agree tier | Backing is vouch-only |
| 5 | Gas reimbursement | The keeper pays its own gas |
| 6 | Catch-up of missed contributions | A missed contribution is simply missed |
| Never cut | Save, money plan, borrow + vouch, queue, pause and waterfall, votes, share-out, Privy sign-in, PWA, the demo | — |

## 6. Risks
| Risk | Mitigation |
|---|---|
| Unknown deadline | Cut lines in §5; the demo path is built first |
| `KuberCircle` exceeds the 24 KB size limit | Move logic into libraries in `src/lib/` (Queue, Waterfall, Weights, Governance); the circle is a clone anyway |
| Rounding drift in the time weights and fees | S1 must match exactly; invariants run every time |
| Privy and local chain quirks | A dev auth mode keeps building and e2e tests independent of Privy; test the Privy flow manually at M9 |
| UI drifts into the generic template look | The UI-SPEC contract plus design reviews at M9 and M10 |
| Scope creep | New ideas go to `.planning` backlog, not into the current milestone |
