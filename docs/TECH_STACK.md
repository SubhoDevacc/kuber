# Kuber — Tech Stack (with reasons)

Rule for every choice: **it has a clear job, it's the simplest tool that does that job well, and there's a reason we didn't pick the alternative.** Local-first: everything runs on a laptop. No Fuji deployment yet.

## 1. System overview

```
 ┌──────────────── apps/web (PWA) ────────────────┐      ┌──── services ────────────────────┐
 │ React + Vite · Privy login → embedded wallet   │─────►│ dev-api (Hono + SQLite)          │
 │ wagmi/viem → contracts · TanStack Query cache  │ HTTPS│  mock KYC · faucet · handles     │
 │ Tailwind + Radix · vite-plugin-pwa (offline)   │      │ keeper (viem) → settle() epochs  │
 └───────────────┬────────────────────────────────┘      └──────────────┬───────────────────┘
                 │ JSON-RPC                                              │ JSON-RPC (admin/keeper keys)
                 ▼                                                       ▼
        ┌──────────────── Anvil local chain (Avalanche-compatible EVM) ───────────────┐
        │ MockUSDC · MockAaveVault · MockLPVault · KuberRegistry · Factory · Circles   │
        └──────────────────────────────────────────────────────────────────────────────┘
 scripts/: deploy · seed · demo (30 wallets) · apy-sync (mainnet APYs from DefiLlama → mock vaults)
 packages/shared: generated ABIs + typed hooks, addresses, zod schemas, labels — used by web, services, scripts
```

## 2. Choices and reasons

### Chain and contracts
| Choice | Why | Not chosen |
|---|---|---|
| **Avalanche C-Chain** (target) | EVM, so standard Solidity tooling works. Sub-second to 2 s finality and low fees fit frequent small payments. It's your chosen chain. | — |
| **Anvil** (local chain, now) | Instant blocks, free gas, and **time travel** (`evm_increaseTime`), so 30-day epochs can be tested in milliseconds. Deterministic. No faucet limits. | Fuji now: slow to iterate, faucet limits; deferred to later |
| **Solidity 0.8.38** (latest stable) with **`evm_version = "cancun"`** | Checked arithmetic and custom errors. Avalanche C-Chain supports **Cancun, not Prague/Pectra**, and newer solc defaults to a later EVM version. Without the pin, bytecode could fail on Avalanche. | Vyper: smaller ecosystem, no OpenZeppelin |
| **Foundry** (forge, anvil, cast) | Tests are written in Solidity. Fastest runner. Built-in **fuzz and invariant testing**, gas reports, coverage. You asked for it. | Hardhat: slower, JS tests, fuzzing needs plugins |
| **OpenZeppelin Contracts 5.x** | Audited ERC20, ERC4626, Clones, SafeERC20, ReentrancyGuard. Never hand-roll security-critical code. | Solmate: less maintained, fewer guardrails |
| **EIP-1167 clones** | Each circle is a cheap proxy of one implementation, and the factory stays under the 24 KB size limit. | `new Circle()`: hits the size limit and costs more gas |
| **Slither + solhint + forge fmt** | Static analysis catches common bugs (reentrancy, unchecked calls). The lint enforces style and security rules. Free and local. | Paid audits: later, before real money |

### Off-chain language and tooling
| Choice | Why | Not chosen |
|---|---|---|
| **TypeScript 6.0** everywhere off-chain | One language for web, services, and scripts. Types come straight from contract ABIs, so contract changes break the build instead of surfacing at runtime. | **TS 7.0** (the new Go compiler) is out, but it has no stable JS API yet, and `typescript-eslint` only supports TS below 6.1. TS 6.0 is the newest version that is fully compatible with the whole toolchain. |
| **Biome** (lint + format for TS/JSON/CSS) | One fast tool replaces ESLint + Prettier, with no plugin version matrix and no dependency on the TypeScript compiler's internals | ESLint + Prettier: two tools, many plugins to keep compatible |
| **Node 26** (installed) | Runs TypeScript directly and has **built-in SQLite**, so services need no build step and no database server. One runtime for everything. | Bun: also good, but it's a second runtime; Node is needed for Vite anyway |
| **pnpm workspaces** | Strict dependencies (no "works on my machine" phantom deps), a fast deterministic lockfile, a clean monorepo. | npm: loose hoisting · Yarn: no advantage here |
| **Vitest** | Native to Vite, fast, Jest-compatible API. Covers `packages/shared`, services, and web logic. | Jest: slower and needs config with Vite |
| **Playwright** | Real browsers (including mobile viewports), so it can test PWA install and offline, plus full user flows against Anvil. | Cypress: weaker multi-tab and mobile support |

### Web app (PWA)
| Choice | Why | Not chosen |
|---|---|---|
| **React 19 + Vite** | Vite builds a **static app**: hostable anywhere and ideal for a PWA. React has the best web3 ecosystem, and Privy's SDK is React-first. | Next.js: we don't need server rendering; its server model complicates wallets and PWA caching |
| **React Router** | Simple, well known, enough for about 15 screens. | TanStack Router: typed but more setup than we need |
| **Privy** (auth + embedded wallets) | Sign in with email, Google, or a passkey, and a **self-custodial wallet is created automatically** (you asked for this). Keys are protected by Privy's secure enclave and key sharding, with recovery built in. Works with wagmi/viem. Free development tier. | Dynamic: similar, heavier · Web3Auth: more config · thirdweb: vendor lock-in · Turnkey: lower level, more code |
| **wagmi + viem** | Typed contract reads and writes, caching, refetch on every block. viem is also used in services and scripts, so there's one library everywhere. | ethers: less typed, would be a second library |
| **@wagmi/cli** (foundry plugin) | Generates typed hooks from Foundry build output, so the frontend can't drift from the contracts. | Hand-copied ABIs: drift bugs |
| **TanStack Query** (comes with wagmi) | Caching, polling, retries, offline-friendly state. | Hand-rolled fetching |
| **Tailwind CSS v4** | Design tokens (type scale, colors, spacing) live in one place, so screens stay consistent. | CSS-in-JS: runtime cost, slower |
| **Radix UI primitives** | Accessible dialogs, sheets, tabs, and menus (keyboard, focus, screen reader) **without imposing a look**, so we design our own UI rather than the generic template look. | shadcn defaults: recognisable template look · MUI: heavy, opinionated styling |
| **lucide-react** | One consistent icon set, imported individually. | Mixed icon packs |
| **Hand-rolled SVG charts** | We only need an allocation donut and a progress bar, about 50 lines. No library weight. | Recharts or visx: overkill for 2 charts |
| **Codex `image_gen`** (gpt-image-2) for images | Tested: it produces real 1024×1024 PNGs. Used for the PWA icon set, onboarding illustrations, and empty states. Images are reviewed, then committed as static files. | Stock illustrations: generic, the template look |
| **zod** | One schema in `packages/shared` that mirrors the contract bounds, validating forms (web) and requests (dev-api) identically. | Duplicated validation |
| **vite-plugin-pwa** (Workbox) | Generates the manifest and service worker, precaches the app shell, and prompts when an update is ready. Standard and minimal config. | Hand-written service worker: easy to get caching wrong |

### Services (local)
| Choice | Why | Not chosen |
|---|---|---|
| **dev-api on Hono** | Tiny, typed, built on Web-standard APIs, about 10 endpoints. It does mock KYC, the faucet, and display names. It **keeps admin keys off the frontend**. | Express: untyped, dated · Fastify: more than we need |
| **SQLite** (Node built-in) | Zero setup, single file. Enough for mock KYC records and profiles. KYC fields are encrypted at rest. | Postgres: a server to run for no benefit yet |
| **keeper** (Node + viem loop) | Settles each epoch on time. Anyone can settle, so the keeper is convenience, not a single point of failure. | Chainlink Automation / Gelato: not on local Anvil; later option |
| **DefiLlama yields API** | Free, **no API key**. Has APYs for Aave v3 USDC on Avalanche and Avalanche DEX pools. A committed snapshot JSON is the fallback. | On-chain Aave reads: works for Aave only, not LP |

## 3. Pinned versions (checked 2026-11-13 against npm, GitHub, and PyPI)

These are the latest stable releases, cross-checked against each other's peer-dependency ranges. Pin them exactly: `pnpm` lockfile, the `packageManager` field, `.nvmrc`, and `foundry.toml`.

| Area | Package / tool | Version | Compatibility notes |
|---|---|---|---|
| Runtime | Node.js | **26.x** (26.8.2 installed; Active LTS) | Vite needs ≥ 22.12; Vitest supports `^22.12 \|\| ^24 \|\| >=26` ✓ |
| Packages | pnpm | **12.18.0** | Set via the `packageManager` field (corepack) |
| Contracts | Solidity (solc) | **0.8.38** | `evm_version = "cancun"` (Avalanche) |
| | Foundry | **v1.9.0** (stable) | `foundryup --install v1.9.0` |
| | OpenZeppelin Contracts | **5.6.1** | pragma ^0.8.20+ ✓ with 0.8.38 and Cancun |
| | Slither | **0.11.6** | `pipx install slither-analyzer==0.11.6` (Python 3.14 installed) |
| | solhint | **6.2.5** | |
| Language | TypeScript | **6.0.3** | wagmi, viem, @wagmi/cli, and abitype need ≥ 5.9.3 ✓; typescript-eslint needs < 6.1 ✓ |
| | Biome | **2.6.7** | |
| Web | React / React DOM | **19.3.1** | |
| | @types/react, @types/react-dom | **19.3.0** | |
| | Vite | **8.3.8** | |
| | @vitejs/plugin-react | **6.3.0** | requires Vite ^8 ✓ |
| | React Router | **8.5.1** | requires React ≥ 19.2.7 ✓ |
| | Tailwind CSS + @tailwindcss/vite | **4.3.5** | supports Vite ^8 ✓ |
| | radix-ui | **1.8.1** | React 19 ✓ |
| | lucide-react | **1.72.0** | React 19 ✓ |
| | vite-plugin-pwa | **2.0.0** | Vite ^8 ✓; peer workbox-build and workbox-window **7.4.1** |
| | zod | **4.6.7** | abitype supports zod ^4 ✓ |
| Chain (web) | wagmi | **3.7.11** | viem 2.x ✓, React Query ≥ 5 ✓, exports `./codegen` ✓ |
| | viem | **2.57.19** | Privy's wagmi adapter needs ^2.57.8 ✓ |
| | @tanstack/react-query | **5.107.1** | |
| | @wagmi/cli | **2.10.1** | foundry and react plugins |
| Auth | @privy-io/react-auth | **3.51.4** | React 19 ✓; Solana and smart-wallet peers are optional (not installed) |
| | @privy-io/wagmi | **4.0.20** | wagmi ≥ 2 ✓, react-auth ^3 ✓ |
| | @privy-io/node (server) | **0.39.0** | replaces the **deprecated** `@privy-io/server-auth`; pre-1.0, so pin exactly |
| Services | hono | **4.13.18** | |
| | @hono/node-server | **2.1.8** | hono ^4 ✓ |
| Tests | Vitest | **5.1.0** | Vite ^8 ✓ |
| | jsdom | **31.0.1** | |
| | @playwright/test | **1.65.0** | |
| | @axe-core/playwright | **4.14.0** | |
| | @lhci/cli | **0.16.1** | |

**Upgrade rule:** don't bump versions mid-build. If one package needs an upgrade, re-check its peer ranges against this table first.

## 4. Agent skills and MCP servers for this stack

These are the official ones, from the vendors themselves. Install them before the build starts. **Read a downloaded skill's text before trusting it.**

| For | What | Install | Use in milestone |
|---|---|---|---|
| OpenZeppelin / Solidity | **OpenZeppelin Skills** (official): `setup-solidity-contracts`, `develop-secure-contracts`, `upgrade-solidity-contracts` | In Claude Code: `/plugin marketplace add OpenZeppelin/openzeppelin-skills` then `/plugin install openzeppelin-skills` | M0–M7 |
| Privy | **Privy Agent Skill** (official) | From the repo root: `npx skills add https://docs.privy.io -a claude-code --project -y` (creates `.claude/skills/privy/SKILL.md`) | M8–M9 |
| Privy docs | **Privy docs MCP** (official) | `claude mcp add privy-docs --transport http https://docs.privy.io/mcp` | M8–M9 |
| Avalanche | **Avalanche Builder Hub MCP** (official, read-only) | `claude mcp add avalanche-mcp --transport http https://build.avax.network/api/mcp` | Chain config, EVM version questions, later Fuji |
| App UI design system | **Impeccable** (`pbakaus/impeccable`): 20 design commands (`init`, `document` → DESIGN.md, `typeset`, `polish`, `live`) plus code-based hooks that flag AI-template patterns. **Primary UI skill**, because it is built for real apps and design systems. | In Claude Code: `/plugin marketplace add pbakaus/impeccable`, then `/plugin` → Discover → install. Then `/impeccable init` and `/impeccable hooks on` | M9–M10 (all app screens) |
| Visual direction | **Anthropic `frontend-design`** (official): a strong visual direction instead of generic defaults | `npx skills add https://github.com/anthropics/skills --skill frontend-design` | M9 start (UI-SPEC) |
| Welcome / landing page | **Taste Skill** (`design-taste-frontend` v2.5.1): art direction plus a real-browser checker. Built for **marketing pages**, not app screens, so it's used **only for P1 Welcome**. Needs Chrome. | `/plugin marketplace add Leonxlnx/taste-skill`, then `/plugin install taste-skill@taste-skill` | M10 (Welcome page polish) |
| Foundry, Vite, React, Tailwind | No official skill. Third-party ones are **not used** (unvetted). | — | — |

**Design skill rule:** one job per skill, so their rules don't conflict:
- Impeccable owns the app design system and its checks.
- `frontend-design` sets the initial direction.
- Taste covers only the Welcome page.

Impeccable's hooks and Taste's scripts run local code, so review them once before trusting them. Both are MIT-licensed and widely used.

## 5. API keys and secrets: what's needed and where

**Only one outside signup is needed: Privy.** Everything else is local or free with no key.

| Name | File | Needed at | How to get it | Secret? |
|---|---|---|---|---|
| `VITE_PRIVY_APP_ID` | `apps/web/.env.local` | M9 (web auth) | [dashboard.privy.io](https://dashboard.privy.io) → create an app → App ID | No (public by design) |
| `PRIVY_APP_ID`, `PRIVY_VERIFICATION_KEY` | `services/dev-api/.env` | M8–M9 | Privy dashboard → App settings → verification key. dev-api uses it to check that requests come from a logged-in user. | Verification key: no. Never store the app secret in the web app. |
| Privy dashboard settings | — | M9 | Enable email, Google, and passkey login. Embedded wallets: **"create on login"**. Allowed origin `http://localhost:5173`. Add a custom chain: Anvil 31337 at `http://127.0.0.1:8545`. | — |
| `ADMIN_PRIVATE_KEY` | `services/.env` | M8 | Anvil default account #0 (local only; it owns the registry and vaults) | Yes. Local dev key, never reused |
| `KEEPER_PRIVATE_KEY` | `services/.env` | M8 | Anvil account #1 | Yes (local) |
| `KYC_ENCRYPTION_KEY` | `services/dev-api/.env` | M8 | `openssl rand -base64 32` | Yes |
| `RPC_URL` (services, scripts) · `VITE_RPC_URL=/rpc` (web, proxied by Vite) | `.env` files | M8 | `http://127.0.0.1:8545` | No |
| *Later:* `FUJI_DEPLOYER_KEY`, block explorer API key | — | Fuji milestone (not now) | Fuji faucet; Routescan/Snowtrace | Yes |
| **Not needed:** DefiLlama, Avalanche public RPC, Codex, WalletConnect | — | — | Privy handles wallets; no RainbowKit, so no WalletConnect project ID | — |

**Rules:**
- Every repo has `.env.example` files and never real `.env` files (they're gitignored).
- Any variable starting with `VITE_` ends up in the browser, so it must never hold a secret.
- dev-api refuses to start in production mode if dev-only flags (faucet, time travel) are on.

**Phone testing:**
- Privy and service workers need HTTPS everywhere except `localhost`, and on a phone `127.0.0.1` means the phone itself.
- So the web app uses **relative URLs** (`/rpc` for Anvil, `/api` for dev-api), and the Vite dev server proxies both.
- One HTTPS tunnel (e.g. `cloudflared`) to the Vite port then serves the app, the chain RPC, and the API together.
- Add the tunnel origin in Privy, and set the Privy custom chain RPC to `<tunnel>/rpc`.

## 6. Deliberately not used (yet)
- Fuji or mainnet deployment, a paymaster or smart accounts (gasless transactions): later. On Anvil the faucet gives gas.
- An indexer such as The Graph or Ponder: about 50 members per circle fit in contract views plus events.
- Push notifications (VAPID): P1.
- Analytics and monitoring: after the demo.
- Real KYC vendor, real Aave or LP, real stablecoin: out of scope for the proof of concept.
