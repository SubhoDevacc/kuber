# Kuber — status

**Updated:** 2026-11-14 08:50 IST (draft; the "In progress" section is rewritten when the sprint finishes)

Kuber is a savings circle on Avalanche. A group saves a fixed amount each round, the pooled money earns, members can borrow against their own savings or with other members backing them. If a borrower stops paying, their own savings pay first, then only the members who backed them. Everyone else loses nothing.

## Done

### Contracts (tested)
- Token, two vault mocks, registry, factory, and the circle contract with ten linked libraries.
- Features: forming and joining, round settlement, investing into vaults, loans and a fair queue, backing, defaults and the loss waterfall, voting (rules, allocation, manager, kick, join), leaving, kicking, joining mid-cycle, fund manager, protocol and manager fees, gas reimbursement.
- 352 tests pass, 0 fail. This includes the SPEC §4 worked example to the unit, property tests, and a stateful invariant suite on two circles that share members.
- Eight planted bugs (mutants) are each caught by a named check.
- Slither (strict): no high or medium finding.
- An independent audit of milestones 5 and 6 rebuilt the worked example and the PRD §7 demo story on the real contracts; both match.

### Milestones committed on branch `build`
M0 scaffold · M1 mocks + registry · M2 circle core · M3 investing · M4 loans + queue · M5 backing + defaults · M6 governance + membership · M7 fees + hardening (plans 1–3 of 5)

## In progress (deadline sprint, ends 2026-11-14 about 12:30 IST)

- One command (`pnpm dev`) for a controlled environment: local chain, real contracts, server, web app.
- Real deploy script and contract addresses file.
- Server: sign-up, 20,000 test mUSDC for every new account, and the tutorial engine (five bot members, server-controlled time).
- Web app: welcome, sign-up, tutorial mode (six chapters with real transactions), finish, minimal app.
- Contracts deployed and verified on Fuji.

## Left (not done; in rough order of value)

### Contracts
1. Governance rule R-J4: a member whose proposal fails cannot propose in the next round; a rule proposal equal to the current value is rejected. Without it one member can keep a proposal slot busy. This blocks a change but moves no money.
2. Eight test gaps found by the audit (the code is correct; a test is missing). List: `.planning/reviews/M6-audit-to-do.md`.
3. Gas tests G1–G3 and the 50-member random scenario S3 as gate tests (the audit measured the heaviest completing call at 8.29M gas against a 12M limit).
4. Coverage report and the 10,000-run fuzz profile (the default profile passes; the long run was stopped for the deadline).
5. Code review, security review, and second-opinion review of M7.

### App and services
6. Real sign-in with Privy (the app ID and secret are set up; the sprint uses a practice wallet in the browser).
7. The full page set in `docs/PAGES.md`: create a circle, explore and join, loans, backing, voting, profile, outside the tutorial.
8. Tutorial extras: the user backs a loan themselves and loses a small pledge; resume across devices.
9. Keeper service for circles outside the tutorial; seed data; APY sync; the unattended demo script.
10. Mock KYC with encrypted storage (the sprint only marks a wallet verified; no ID data is collected).
11. Offline support (PWA), end-to-end browser tests, Lighthouse, accessibility audit.

### Hosting
12. A hosted version for testers: the tutorial on Fuji in real time (short rounds, gas top-up for new accounts), server on Railway. Plan outline: `.planning/BACKLOG.md`.

## How to run

Filled in when the sprint finishes.
