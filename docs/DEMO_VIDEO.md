# Kuber — Demo Video Script

**This is the full version, for after the submission.** Today's short cut, recorded from the sprint build where the tutorial is the app, is in [DEMO_VIDEO_SUBMISSION.md](DEMO_VIDEO_SUBMISSION.md).

28 short clips. Each clip answers one question and also works alone. The story and numbers follow [PRD.md](PRD.md) §7.

Two cuts are stitched from the same clips:
- **Main:** the 18 story clips, about 7 min 10 s.
- **Full:** all 28 clips, about 10 min. It covers every P0 feature in PRD §5, plus tutorial mode.

## 1. Format
- **Frame:** 9:16 vertical, 1080×1920, phone view.
- **Voice:** AI voice, English, one voice for every clip. The Voiceover column is the text to generate. It never says "mUSDC"; amounts are spoken as plain numbers.
- **Two clip types:**
  - *Motion graphics:* rendered from code. Needs the app's logo, colours and fonts (the design system from M9).
  - *Phone:* a recording of the real app in a phone-size window, driven by `demo.ts --live`. Needs M9.
- **App modes:** the app has two modes (`.planning/BACKLOG.md`, 2026-11-14).
  - *Tutorial mode:* a new account starts here after onboarding, in a practice circle with 5 practice members and a guide panel. Clip T1 shows it.
  - *Real app:* every other phone clip. Alice has finished the tutorial, so her practice circle is hidden.
- **Network:** everything is recorded on local Anvil, where the script can skip time between rounds.
- **Main circle:** "Sunrise Circle": 30 members, 100 per round, 7 rounds.
  - Alice (creates, borrows), Bob (vouches for Alice), Carol (only saves), Dave (defaults), Frank (vouches for Dave), Erin (agrees for Dave), 24 bots.
- **Second circle:** "Harbor Circle", small, for the clips that would change the main story's numbers.
  - Grace (leaves), Heidi (fund manager), Ivan (joins late), Judy (is removed).

## 2. Clip list
Clips play in this order. "Full" clips are skipped in the Main cut.

| # | Question | Type | Phone | Length | Cut |
|---|---|---|---|---|---|
| A1 | What is Kuber? | Motion graphics | — | 24 s | Main |
| A2 | How does it work? | Motion graphics | — | 20 s | Main |
| B0 | Do I need the app store? | Phone | Alice | 12 s | Full |
| B1 | How do I start? | Phone | Alice | 28 s | Main |
| T1 | How do I learn it? | Phone, tutorial mode | Alice | 28 s | Main |
| B10 | How do I find a circle? | Phone | Ivan | 20 s | Full |
| B2 | How do I make a circle? | Phone | Alice | 28 s | Main |
| B3 | How does my friend join? | Phone | Bob | 24 s | Main |
| B4 | How do I save? | Phone | Alice | 24 s | Main |
| B5 | Where does the money go? | Phone | Alice | 20 s | Main |
| B11 | Can an expert manage the money? | Phone | Heidi | 24 s | Full |
| B6 | How do I borrow? | Phone | Alice | 28 s | Main |
| B7 | How does a friend back me? | Phone | Bob | 24 s | Main |
| B8 | Who decides? | Phone | Alice | 28 s | Main |
| B9 | How do I repay? | Phone | Alice, Bob | 24 s | Main |
| B12 | Where is my record? | Phone | Alice | 16 s | Full |
| C1 | What if I miss a payment? | Phone | Dave | 24 s | Main |
| C2 | What if someone doesn't repay? | Phone + motion graphics | Dave | 28 s | Main |
| C3 | What happens to the person who defaulted? | Phone | Dave | 20 s | Main |
| C4 | What if I want to leave? | Phone | Grace | 20 s | Main |
| C5 | What if the organiser runs off? | Motion graphics | — | 16 s | Main |
| C6 | What if I want to join a circle that already started? | Phone | Ivan, Heidi | 24 s | Full |
| C7 | What if the group wants someone out? | Phone | Heidi, Judy | 20 s | Full |
| C8 | What if the investments lose money? | Motion graphics | — | 16 s | Full |
| C9 | What if not enough people join? | Phone | Ivan | 12 s | Full |
| C10 | What if I lose my phone? | Phone | Alice | 12 s | Full |
| C11 | What does Kuber charge? | Motion graphics | — | 12 s | Full |
| D1 | How does it end? | Phone + outro | Carol | 24 s | Main |

## 3. Part A — What it is

### A1. What is Kuber? (24 s)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–4 s | "Your savings group runs on trust." | A paper ledger page with names and tick marks, already on screen at frame 0 | People everywhere save together in groups. It all runs on trust, and a notebook. |
| 4–8 s | "The organiser can run off." | The pot total counts 3,000 down to 0; the organiser's row is struck out | But the organiser can run off with the pot. |
| 8–12 s | "The money sits idle." | The pot sits still; an "earned" counter stays at 0 | The money just sits there, earning nothing. |
| 12–16 s | "One default hurts everyone." | 30 dots; one turns red, then all 30 dim | And when one person doesn't repay, everybody pays for it. |
| 16–20 s | "Kuber" | The ledger folds away; the wordmark lands on the beat | Kuber is a savings circle where the rules hold the money, not a person. |
| 20–24 s | "Don't back anyone. Lose nothing to a default." | The same 30 dots: one red, two amber backers, 27 stay green | And if you don't back anyone, nobody else's default can touch your savings. |

### A2. How does it work? (20 s)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–4 s | "Save every round." | 30 dots each drop a coin into the pot; the pot counts up to 3,000 | Everyone in the circle saves the same amount every round. |
| 4–8 s | "The pot gets invested." | The pot splits into four bars: 5 / 50 / 35 / 10 | The group votes on where the pot is invested, so it earns. |
| 8–12 s | "Borrow up to 90% of your savings." | A savings bar of 300; 270 of it lights up | Need money? Borrow up to ninety percent of what you've saved. |
| 12–16 s | "Need more? Friends back you." | A second bar of 80, labelled Bob, attaches to the first | Need more? Friends can back you, and they earn for it. |
| 16–20 s | "Everyone else is safe." | 30 dots: one red, two amber, 27 green | If a loan goes bad, only the borrower and their backers pay. |

## 4. Part B — Each feature

### B0. Do I need the app store? (12 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Browser: the Kuber page with "Install app" | Install app | Kuber installs straight from the browser. No app store. |
| 4–8 s | The phone's home screen: the Kuber icon appears | Open | It sits on your home screen like any other app. |
| 8–12 s | The app with its "You're offline" banner over the saved view | — | And it still opens when your signal drops. |

### B1. How do I start? (28 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Welcome: "Save together. Borrow with your friends' backing." | Sign in | Open Kuber and sign in with your email. |
| 4–8 s | Email and code entry, then the caption "Wallet created. No seed phrase." | Enter code | A wallet is made for you in the background. Nothing to write down. |
| 8–12 s | Choose a display name: "Alice" | Continue | Pick a name your friends will know. |
| 12–16 s | Verify identity (the form is marked "test only"), then the Verified badge | Verify | Verify once, so each person has one account. |
| 16–20 s | Notice: "20,000 test mUSDC added"; the balance shows 20,000 | — | Every new account starts with twenty thousand in test money. |
| 20–24 s | Add money: "Buy with card" or "Transfer from another wallet" | Transfer | Need more? Buy with a card… |
| 24–28 s | QR code, wallet address, Copy button | — | …or scan this code to send from a wallet you already have. |

### T1. How do I learn it? (28 s, Alice, tutorial mode)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | After onboarding: the practice circle opens under a "Tutorial mode" banner | Start | New accounts start in tutorial mode: a practice circle to learn in. |
| 4–10 s | The practice circle: Alice and 5 practice members. The guide panel lists six chapters: Join and save · Borrow · Back someone · Vote · Default · Share-out | — | Five practice members join you, and a guide walks you through six short chapters. |
| 10–16 s | Guide panel: "Pay your first round". After the tap, the "What just changed" card shows before and after numbers and a transaction link | Pay | Each step is one real action. Then a card shows what just changed, with the transaction behind it. |
| 16–22 s | The Default chapter: Dave's savings pay first, his backers cover the rest, and Alice loses only what she pledged | — | You even watch a practice member default, and see exactly who pays. |
| 22–28 s | "You're ready", then Explore in the real app. The menu shows the tutorial mode switch | Continue | Finish, or skip, and you're in the real app. You can come back from the menu any time. |

### B10. How do I find a circle? (20 s, Ivan)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Explore: the circle cards | Explore tab | Every circle on Kuber is public. |
| 4–10 s | Filters: amount per round, size, risk level | Filter | Filter by how much you save per round, the group size, and the risk level. |
| 10–16 s | One card: members, rounds left, mini money-plan donut, earnings so far, default rate | Open | Each card shows its money plan, what it has earned, and how often its members default. |
| 16–20 s | Circle page, public view | — | Open one and read everything before you commit. |

### B2. How do I make a circle? (28 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Home, empty state: "Explore circles or create one" | Create | Alice wants to save with people she knows, so she starts a circle. |
| 4–10 s | Step 1, Basics: "Sunrise Circle", 100 per round, 7 rounds, start date | Next | She gives it a name, the amount each person saves per round, and a start date. |
| 10–16 s | Step 2, People: she adds Bob, Carol, Dave, Erin and Frank by name | Next | Then she invites her friends. A circle needs at least five people. |
| 16–20 s | Step 3, Money plan: sliders at 5 / 50 / 35 / 10 | Next | The money plan comes with safe defaults. She leaves it as it is. |
| 20–24 s | Step 4, Review: the rules in plain words | Create circle | One last look at the rules in plain words, and she creates it. |
| 24–28 s | Circle page: "Forming", countdown to the start date, invites sent | — | The circle is open, waiting for her friends. |

### B3. How does my friend join? (24 s, Bob)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Bob's Home: "Alice invited you to Sunrise Circle" | Open | Bob gets Alice's invite. |
| 4–10 s | Circle page, public view: rules, money plan, members | Scroll | Before joining, he can see everything: the rules, where the money goes, and who's in. |
| 10–14 s | Join sheet | Join | He taps Join. |
| 14–18 s | "You're in. Starts in …" | — | No money moves until the circle starts. |
| 18–24 s | The member count climbs to 30; the status changes to "Round 1 of 7" | — | On the start date the circle begins on its own, now thirty people strong. |

### B4. How do I save? (24 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Home: "Due this round" card, 100, time left | Pay now | Each round, Home shows what's due. |
| 4–8 s | Pay sheet: "You pay 100 · Your savings become 100" | Pay | The sheet tells you exactly what happens before you confirm. |
| 8–12 s | The card changes to "Paid for round 1" | — | Paid. That's round one. |
| 12–18 s | Round 2 closes without a tap; Activity shows "Auto-paid 100 for round 2" | — | Forget to pay? When the round closes, Kuber takes it from your balance for you. |
| 18–24 s | Overview: "Round 2 of 7", my savings 200, 30 members on track | — | Thirty people, saving round after round. |

### B5. Where does the money go? (20 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Circle → Money: the donut | Money tab | The pot doesn't sit idle. |
| 4–12 s | The segments highlight one by one: Loans 5%, Aave 50%, LP 35%, Cash 10%, each with its rate | — | Five percent is kept for loans. Half goes to Aave, thirty-five percent to a liquidity pool, and ten percent stays as cash. |
| 12–16 s | The "from Avalanche mainnet" label and "Yield earned". Caption: "Demo: mock vaults, mainnet rates" | — | The rates you see are the live rates on Avalanche. |
| 16–20 s | The savers' bonus line | — | Gains and losses from investing are shared by everyone. |

### B11. Can an expert manage the money? (24 s, Heidi, Harbor Circle)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Votes: "Appoint Heidi as fund manager", then "Passed" | Vote | A circle can vote in a fund manager: a member who knows investing. |
| 6–12 s | Money tab: the manager card with rounds managed and average earnings per round | — | Her track record is public for everyone to check. |
| 12–18 s | Heidi's Propose sheet: a new money plan, which then appears under Votes | Create proposal | She proposes changes to the money plan, but every change still goes to a vote. |
| 18–24 s | Votes: the manager fee rule ("up to 10% of earnings") and "Remove fund manager" | — | The group sets her fee, and can vote her out. |

### B6. How do I borrow? (28 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Circle → Loans: "You can borrow up to 270" | Borrow | After three rounds, Alice can borrow. She has saved 300, so her limit is 270. |
| 4–10 s | Borrow sheet, slider at 350: "From your savings 270 · Needs backing 80" | Drag slider | She needs 350. 270 comes from her own savings. The other 80 needs a friend's backing. |
| 10–16 s | Rate offered to backers: 8%. Installments: 2 | Set both | She offers her backers eight percent, and picks two repayments. |
| 16–20 s | Total cost line | Request loan | She sees the full cost before she confirms. |
| 20–28 s | "Share backing link", then the status view: "Backing 0 of 80" | Share | Then she sends the request to Bob. |

### B7. How does a friend back me? (24 s, Bob)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Bob's Home: "Alice needs backing: 80" | Open | Bob gets Alice's request. |
| 4–10 s | Back a loan sheet: Alice's history, loan terms, Vouch or Agree | Vouch | He can vouch: cover a loss first and earn the full eight percent. Or agree: cover second and earn half. |
| 10–16 s | Amount 80. "If Alice doesn't repay, you could lose up to 80." | Back this loan | He vouches 80. The risk is spelled out in money, not percentages. |
| 16–20 s | Alice's status view: "Backing 80 of 80", then her queue position | — | Bob's savings never leave the pot. Alice's request joins the queue. |
| 20–24 s | The queue: fast lane and line | — | Pay extra for the fast lane, or wait in line. The line always moves. |

### B8. Who decides? (28 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Loans tab: loan reserve 450; requests from Alice (350) and Dave (350) | — | There's a problem. The loan reserve holds 450, and two loans of 350 are waiting. |
| 6–12 s | Propose sheet: new money plan, Loans 10%, Aave 45%, with the effect in words | Create proposal | So Alice proposes a new money plan: ten percent for loans, taken from Aave. |
| 12–20 s | Votes tab under the "Open: requests and votes" chip: the bar climbs to 16 of 30, then "Passed" | — | Everyone has the rest of the round to vote. Sixteen of thirty say yes. |
| 20–28 s | The round closes; the donut changes; both loans show "Funded" | Claim | When the round closes, the new plan applies and both loans are funded. Alice claims her 350. |

### B9. How do I repay? (24 s, Alice then Bob)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Alice's Home: the due card shows her saving plus a loan payment | Pay now | Alice repays in two payments, alongside her normal saving. |
| 6–10 s | Her loan view: the "Pay off early" button | — | She could also pay it all off early. |
| 10–16 s | Second payment, then "Loan repaid, on time" | Pay now | Second payment, and the loan is closed, on time. |
| 16–24 s | Bob's Activity: "You earned 6.4 for backing Alice"; his backing at risk returns to 0 | — | Bob earns 6.4 for backing her, and his 80 is free again. |

### B12. Where is my record? (16 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Activity: the feed across her circles | Activity tab | Activity shows everything that happened in your circles. |
| 4–10 s | Profile: Verified badge, history across circles, loans repaid on time | Profile tab | Your profile is your record: circles finished, loans repaid on time. |
| 10–16 s | Profile: wallet address, Copy, Export wallet | — | And the wallet is yours. You can export it whenever you like. |

## 5. Part C — What if

### C1. What if I miss a payment? (24 s, Dave)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Members tab: Dave, "1 payment behind" | — | Miss a payment and your status changes for everyone to see. |
| 4–10 s | Dave's Pay sheet: overdue amounts with their fines | Open Pay | A small fine is added each round you're late: one percent on a missed saving, three percent on a missed loan payment. |
| 10–16 s | "Pay all" button | — | You can catch up any time with one tap, and you're back on track. |
| 16–20 s | Next round: "2 behind" | — | Fall two behind, and the fines keep adding up. |
| 20–24 s | Caption: "At 3 behind, you're paused." | — | At three, you're paused. |

### C2. What if someone doesn't repay? (28 s, Dave's phone, then motion graphics)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–4 s | Phone: Dave, "Paused" | The red badge on the Members tab | Dave is three payments behind. He's paused, and his loan is settled on the spot. |
| 4–8 s | "Dave owes 350" | An empty bar marked 350 | He owes 350. |
| 8–12 s | "Dave's own savings: 300" | The bar fills to 300 | First, his own savings pay: 300. |
| 12–16 s | "Frank, voucher: 30" | The bar fills to 330 | Then Frank, who vouched for him, covers 30. |
| 16–20 s | "Erin, agreer: 20" | The bar fills to 350 | Then Erin, who agreed to back him, covers the last 20. |
| 20–28 s | "The other 27 lose 0" | 30 dots: one red, two amber, 27 green, each with a 0 | The other twenty-seven members lose nothing. They never backed him, so his default can't touch them. |

### C3. What happens to the person who defaulted? (20 s, Dave)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Debt page: what he owes and to whom | — | The debt doesn't disappear. It follows Dave. |
| 6–12 s | Explore: Join is blocked, "Pay your debt to join new circles" | Join | He can't join or start another circle until it's paid. |
| 12–16 s | Debt page: "Money you're owed pays this first" | — | Any money he's owed from any circle goes to the debt first. |
| 16–20 s | Repay button and its effect: "Frank and Erin are repaid. You're reinstated." | — | When he pays, Frank and Erin get their money back, and Dave is reinstated. |

### C4. What if I want to leave? (20 s, Grace, Harbor Circle)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Overview: "If you leave now you get …" | Leave | You're never locked in. Overview always shows what you'd get if you left now. |
| 6–12 s | Leave sheet: savings + earnings − 3% fee | — | That's your savings plus your earnings, minus a three percent early-exit fee, which goes to the savers who stay. |
| 12–16 s | "You'll leave when this round ends" | Leave | Tap Leave, and you're paid when the round closes. |
| 16–20 s | Caption: "Finish your loan and your backing first." | — | The only catch: finish your loan and your backing first. |

### C5. What if the organiser runs off? (16 s)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–4 s | "Who holds the pot?" | The ledger from A1 turns into a locked box | In Kuber, no person holds the pot. |
| 4–8 s | "Pay in · Invest · Lend · Pay out" | Four arrows in and out of the box, one at a time | It sits in a contract that only moves money by the circle's rules. |
| 8–12 s | "No vote can take a member's money." | A vote bar fills, and the box stays shut | The group can vote on the plan, but no vote can take a member's money. |
| 12–16 s | "Every circle is public." | The box turns see-through and shows its rules | And every circle is public, so you can check the rules and the record before you join. |

### C6. What if I want to join a circle that already started? (24 s, Ivan then Heidi, Harbor Circle)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–4 s | Ivan: circle page, public view, "Round 4 of 7" | Apply | A circle that has already started can still take you in. Tap Apply. |
| 4–10 s | Heidi: Members tab, applicant Ivan | Sponsor | One member has to sponsor you. It goes on their record, so they choose carefully. |
| 10–16 s | Votes: "Admit Ivan", then "Passed" | — | Then the group votes. |
| 16–20 s | Next round, Ivan's Home: the "Due this round" card | Pay now | If it passes, you're in from the next round, and you start saving. |
| 20–24 s | Caption: "Borrow and vote after 3 paid rounds." | — | Like everyone else, you can borrow and vote after three paid rounds. |

### C7. What if the group wants someone out? (20 s, Heidi then Judy, Harbor Circle)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Heidi's Propose sheet: "Remove a member", Judy | Create proposal | A member can propose removing someone from the circle. |
| 6–12 s | Votes: the bar reaches two-thirds, then "Passed" | — | It takes two-thirds of the group, and the person can't vote on it. |
| 12–16 s | Judy's phone: "You were removed. You get …" with no fee line | — | They leave with their full savings and earnings. No fee, nothing taken. |
| 16–20 s | Caption: "A member with a loan or backing can't be removed." | — | And nobody with a loan or backing can be removed. |

### C8. What if the investments lose money? (16 s)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–4 s | "Investments can go down." | The money-plan donut; the LP slice shrinks | Investing carries risk. The pool can lose value. |
| 4–8 s | "The loss is shared." | 30 dots each lose a thin slice, sized by their savings | If it does, the loss is shared by everyone, in proportion to their savings. |
| 8–12 s | "The group sets the risk." | The money-plan sliders stop at their limits: LP at most 50%, cash at least 5% | The group chooses how much risk to take, within safe limits. |
| 12–16 s | "The promise covers defaults." | 30 dots: one red, two amber, 27 green | Kuber's promise is about defaults: if you don't back a loan, it can never cost you. |

### C9. What if not enough people join? (12 s, Ivan)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | A forming circle: "3 of 5 joined"; the countdown reaches 0; the status changes to "Cancelled" | — | A circle needs five members by its start date. If it doesn't get there, it's cancelled. |
| 6–12 s | Caption: "No money moved." | — | Nothing is lost, because no money moves until a circle starts. |

### C10. What if I lose my phone? (12 s, Alice)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | A new phone: Welcome, sign in with the same email, then Home with her circles and savings | Sign in | Sign in with the same email on any phone, and your circles and savings are there. |
| 6–12 s | Profile: Export wallet | — | There's no seed phrase to lose. |

### C11. What does Kuber charge? (12 s)
| Time | On screen | Visual | Voiceover |
|---|---|---|---|
| 0–6 s | "10% of investment earnings." | An earnings bar; one tenth slides off to Kuber | Kuber takes ten percent of what the investments earn. |
| 6–12 s | "No earnings, no fee." | The earnings bar at 0 with nothing sliding off; the savings bar untouched | If there are no earnings, there's no fee. Kuber never takes a cut of your savings. |

## 6. Part D — The end

### D1. How does it end? (24 s, Carol)
| Time | Screen | Tap | Voiceover |
|---|---|---|---|
| 0–6 s | Share-out: the final table | — | After the last round, everyone is paid out. |
| 6–14 s | Carol's payout: savings + investment earnings + savers' bonus | — | Carol never borrowed. She gets her savings back, her share of the earnings, and the savers' bonus: the interest, fines and fees paid by others. |
| 14–18 s | Withdraw, then her balance | Withdraw | One tap to withdraw. |
| 18–24 s | Outro: the Kuber wordmark and "Save together. Borrow with your friends' backing." | — | Kuber. Save together. Borrow with your friends' backing. |

## 7. Look and effects
**Phone clips**
- The real recording sits inside a phone frame on a plain brand-colour background.
- A question card opens each clip: the question in large type over the first second, then it slides up to stay as a small title.
- A ripple marks every tap, so the viewer sees where the finger went.
- The camera pushes in on the one number that matters in each step (for example "From your savings 270 · Needs backing 80"), then pulls back.
- A name tag with a portrait slides in whenever the phone changes owner: "Bob · Alice's friend".
- Captions are burned in and timed to the voice, for viewers watching without sound.

**Motion-graphics clips**
- Spring movement for anything with weight; counters count up and land on the beat.
- The same 30 dots return in A1, A2, C2 and C8, so "27 lose 0" is recognisable at a glance.
- One accent colour, plus one "bad" colour for defaults. No gradients, glow or particle bursts.

**Between clips**
- A sideways camera move with motion blur, landing on the beat.

**Sound**
- An original music track at 120 beats per minute, so every cut lands on a bar line.
- Short sound effects for taps, cuts and the moment a number lands.
- The music drops under the voice. Final loudness is −14 LUFS.

**Images from Codex `image_gen`** (illustration only, never app screens)
| Image | Used in |
|---|---|
| Portraits of Alice, Bob, Carol, Dave, Erin, Frank, Grace, Heidi, Ivan and Judy, in one style | Name tags |
| The paper ledger page and the pot | A1, A2, C5 |
| The locked box | C5 |
| Cover image | The video thumbnail |

## 8. What the recording needs
| Need | Why | Where it comes from |
|---|---|---|
| The web app | Every phone clip | M9 |
| The welcome grant: 20,000 test mUSDC at first sign-in, with its notice | B1 | M8 (08-CONTEXT D-11b) and M9 |
| An **Add money** screen: Buy with card (faked; the dev faucet sends the money) and a QR with the wallet address (real) | B1 | M9 (BACKLOG) |
| Tutorial mode: banner, guide panel, six chapters, "What just changed" card, "You're ready" | T1 | Its own slice after the M9 pages (BACKLOG) |
| `demo.ts --live` where **Alice creates the circle** and the bots join after her invites | B2, B3. PRD §7 has her open an existing circle | A change to the M8 demo script |
| Persona switch in the dev panel | Every clip that isn't Alice's | PAGES.md P16 |
| "Harbor Circle", seeded with a manager vote, a late joiner, a removal and a leaver | B11, C4, C6, C7. These would break the main story's numbers ("the other 27 lose 0") | `seed.ts` |
| A forming circle with only 3 members | C9 | `seed.ts` |
| Logo, colours, fonts | Motion-graphics clips, name tags and the outro | The M9 design system |
| An AI voice tool and its API key in `.env` | Voiceover audio | You |
