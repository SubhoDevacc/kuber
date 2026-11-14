# Kuber — status

**Updated:** 2026-11-14

## Done

### Contracts (tested, deployed on Fuji)
- Token, two vault mocks, registry, factory, and the circle contract with ten linked libraries.
- Features: forming and joining, round settlement, investing into vaults, loans and a fair queue, backing, defaults and the loss waterfall, voting (rules, allocation, manager, removing a member, late joiner), leaving, joining mid-cycle, fund manager, protocol and manager fees, gas reimbursement.
- 353 tests pass, 0 fail: unit tests, the SPEC §4 worked example to the unit, property tests, a stateful invariant suite on two circles that share members, and a deploy test.
- Eight planted bugs (mutants) are each caught by a named check.
- Slither (strict): no high or medium finding.
- An independent audit of milestones 5 and 6 rebuilt the worked example and the PRD §7 demo story on the real contracts; both match.
- Deployed to Avalanche Fuji and verified (all 16 contracts and libraries). Addresses: `deployments/fuji.json` and the README.

### Controlled test environment
- `pnpm dev` starts a local chain, deploys the real contracts, and starts the server and the web app.
- The server controls time on the local chain, so the tutorial never waits for a round and gives the same numbers every run.

### Server
- Sign-up with a display name; marks the wallet verified; gives 20,000 test mUSDC once per account.
- Tutorial engine: one practice circle per user with five practice members (Bob, Cara, Dave, Erin, Frank), 14 steps in six chapters.
- An end-to-end test plays the whole tutorial as a user, with two users one after the other, and checks every payout to the unit.

### Web app
- Welcome, sign-up, tutorial mode, finish screen, and a minimal app (circle list and circle page).
- Every tutorial step that needs the user is a real transaction signed by a practice wallet in the browser.
- After each step a "What just changed" card shows the before and after numbers.
- Works at phone and laptop width; an automated accessibility scan of the main screens found no violations.

## Left (not built yet; in rough order of value)

### Tutorial and app
1. Real sign-in with Privy. The app uses a practice wallet made in the browser.
2. The user backing someone else's loan in the tutorial (today the user sees backing from the borrower's side, and sees Dave's backers lose).
3. Two tutorials at the same moment on one server. Time is shared on the local chain, so two users running at once can push each other's circle past a round. One user after another works.
4. The full page set in `docs/PAGES.md` outside the tutorial: create a circle, explore and join, loans, backing, voting, profile.
5. The circle list shows every practice circle on the server, not only the caller's.
6. Server state is in memory. Restart the server together with the chain (`pnpm dev` does).

### Hosting
7. A hosted version for testers. Two ways: the same controlled environment on a server, or the tutorial on Fuji in real time (short rounds, gas top-up for new accounts).

### Contracts
8. Governance rule: a member whose proposal fails cannot propose in the next round, and a rule proposal equal to the current value is rejected. Without it one member can keep a proposal slot busy. This blocks a change but moves no money.
9. Eight test gaps found by the audit (the code is correct; a test is missing).
10. Gas tests and the 50-member random scenario as gate tests (the audit measured the heaviest completing call at 8.29M gas against a 12M limit).
11. Coverage report and the 10,000-run fuzz profile (the default profile passes; the long run was not finished).
12. Code review, security review and a second-opinion review of the fees and hardening work.

### Services
13. Mock identity check with encrypted storage (today the server only marks a wallet verified; no ID data is collected).
14. Seed data, APY sync, and the unattended 30-member demo script.
15. Offline support, end-to-end browser tests in the repo, Lighthouse.

## How to run

See the README: `pnpm install`, `pnpm dev`, open <http://localhost:5173>.
