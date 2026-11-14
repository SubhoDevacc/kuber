# Kuber — Submission Video (explainer script)

This is the script for the submission video. The angle is friends: we already ask friends for loans and for investing tips, and Kuber turns that into a circle with rules. It explains what Kuber does, what it fixes and who needs it, then shows it working: first in the tutorial, then in the real app on Avalanche Fuji.

There is no time limit. The narration is about 1,000 words, which is roughly six to seven minutes with the screen actions.

The 28-clip script in [DEMO_VIDEO.md](DEMO_VIDEO.md) is the older, longer plan for after the submission.

## 1. Format
- **Frame:** 9:16 vertical, 1080×1920, phone view.
- **Voice:** the approved narrator (a confident young man, light bass), made locally with `~/voice/kuber/make.sh`. The text the voice reads is in `~/voice/kuber/clips/`, with amounts spelled as they are said.
- **Timing:** the voice is recorded first and the picture is cut to it, so the tables below have no times.
- **Look:** the app's own green and gold, with its rounded heading font.

### How it stays easy to follow
- One idea per beat, and two or three sentences at most.
- The picture changes on every beat.
- The key phrase or number appears on screen as it is spoken.
- A strip at the top always shows where you are: the part, and the chapter inside the tutorial.
- The four problems from Part 1 stay as a checklist and are ticked off in Part 7.

## 2. Parts
| # | Part | Type |
|---|---|---|
| 1 | The problem | Motion graphics |
| 2 | What Kuber does | Motion graphics |
| 3 | Where it is needed | Motion graphics |
| 4 | Getting started | Phone |
| 5 | Learning it in a practice circle (six chapters) | Phone, tutorial mode |
| 6 | The real app | Phone, Avalanche Fuji |
| 7 | What it fixes | Motion graphics |
| 8 | What this build is | Text card |
| 9 | Close | Outro |

## 3. Script

### Part 1. The problem
| # | On screen | Voiceover |
|---|---|---|
| 1.1 | Two chat bubbles: "Can you lend me 200?" and "What should I invest in?" | When you need money fast, you ask a friend first. And when you have money to invest, you ask the friend who always seems to get it right. |
| 1.2 | A group chat scrolling past an unanswered "did you pay me back?" | Both of these run on group chats and memory. Somebody lends 200, somebody forgets, and nobody wants to be the one who brings it up. |
| 1.3 | One friend's tip message; five others each staring at their own phone | The friend with good investing tips can only give tips. Everyone still invests alone, and half the group never gets around to it. |
| 1.4 | Coins from the group drop into one pot, then "It fails in four places." | Some groups go further and pool money every month. That fails in four places. |
| 1.5 | A checklist builds, one line per problem: 1 The pot can leave · 2 Who paid? · 3 Idle money · 4 One default hits everyone | One. Somebody has to hold the pot, and that person can leave with it. Two. The records sit in a chat or a notebook, so people argue about who paid. Three. Between loans the money sits idle and earns nothing. Four. When one member doesn't repay, the loss comes out of everyone's savings. |
| 1.6 | "Deposit 100, borrow 70" | Lending apps on a blockchain don't help here. They lend you less than you deposit, so they give nothing to a person who needs a little more than they have. |

### Part 2. What Kuber does
| # | On screen | Voiceover |
|---|---|---|
| 2.1 | The Kuber wordmark, then "5 to 50 friends · the same amount every round" | Kuber puts that group of friends into one app. Five to fifty people save the same amount every round. |
| 2.2 | The pot moves into a box marked "contract" | A contract holds the pot, and it moves money only the way the circle's rules allow. |
| 2.3 | One dot gets a "fund manager" tag; the pot splits into cash, loans and investments; a vote bar fills | The friend who is good at investing can run the money plan. The circle votes them in as fund manager, they propose where the pot goes, and every change still needs a vote. |
| 2.4 | A savings bar of 300 with 270 lit; a second bar of 80 attaches, marked "a friend's backing" | You can borrow up to ninety percent of your own savings without a backer. For more than that, a friend backs the extra with their savings, and earns interest for taking the risk. |
| 2.5 | A backing card: "You could lose up to 80 · You earn 6.40" | Before they agree, they see what they could lose and what they will earn. |
| 2.6 | Six dots: one red, two amber, three green with a 0 | If a borrower stops paying, their own savings cover the loss first and their backers cover the rest. A member who backed nobody loses nothing to that default. |

### Part 3. Where it is needed
| # | On screen | Voiceover |
|---|---|---|
| 3.1 | "For any group that trusts each other with money" | Kuber is for any group that already trusts each other with money. |
| 3.2 | Two friends and a calendar with a payday circled | Friends who cover each other between paychecks. |
| 3.3 | A set of house keys | Flatmates saving for a deposit. |
| 3.4 | One desk with a chart on screen, others leaning in | Colleagues who follow one person's investing tips. |
| 3.5 | A map with three pins joined by lines | A family spread across countries. |
| 3.6 | Four name tags: chit fund · tanda · susu · stokvel | And community savings groups, known as chit funds, tandas, susus or stokvels, depending on where you live. |
| 3.7 | The app's sign-in screen | None of them needs to know anything about crypto. You sign in with an email, and the app makes the wallet. |

### Part 4. Getting started
| # | Screen | Tap | Voiceover |
|---|---|---|---|
| 4.1 | Welcome: "Save your money together." | Sign in | Open Kuber and sign in with your email. The app creates a wallet for you on Avalanche's test network. |
| 4.2 | Choose a name, then "Verify me (test only)", then the 20,000 test mUSDC notice | Continue, Verify | Pick a name, tap Verify, and twenty thousand in test money arrives. |
| 4.3 | The "test money, no real ID" note | — | Nothing here is real money, and no real ID is needed. |

### Part 5. Learning it in a practice circle
| # | Screen | Tap | Voiceover |
|---|---|---|---|
| 5.0 | The "Tutorial mode" bar; the practice circle with six members | — | New accounts start in tutorial mode. You get a practice circle with five members the app runs: Bala, Chitra, Dev, Esha and Farhan. Every step you take is a real transaction against the real Kuber contracts, on a private practice chain. |
| 5.1a | Chapter 1, "Join or create a circle"; then "Create your circle" | Create a circle, Create the circle | Chapter one is joining and saving. You can join Bala's circle, or create your own and invite the other five. |
| 5.1b | "Allow your savings", then rounds 1 and 2 closing; savings 100, then 200 | Allow, Continue | You give the circle permission to collect your savings, one round at a time. Each round, all six members put in 100, and the circle collects it when the round closes. |
| 5.1c | "Your money at work": the pot split into cash, ready to lend, and invested | Continue | After two rounds the pot is working. Some is kept as cash, some is ready to lend, and the rest is invested. |
| 5.2a | Chapter 2, "Save round 3 early" | Pay 100 now | Chapter two is borrowing. You need three rounds of savings to borrow, so you pay round three early. |
| 5.2b | "Ask for a loan": 350 = 270 from your savings + 80 backed by Bala | Ask for 350 | Then you ask for 350. 270 can come from your own 300 in savings. The other 80 needs a backer, so Bala puts 80 of his savings on hold for your loan, and you pay him eight percent for it. |
| 5.2c | "Your loan is ready", then "Take your loan"; the wallet goes up by 350 | Take 350 | When the round closes the loan is ready, and you move 350 into your wallet. |
| 5.2d | Loans: Dev, 350, backed by Chitra and Esha | — | Dev borrows 350 in the same round, backed by Chitra and Esha. |
| 5.3 | Chapter 3, "Repay, part 1" and "Repay, part 2"; then "Loan repaid" | Pay, Pay | Chapter three is repaying. You pay the loan back over two rounds, together with your normal savings. After the second payment the loan is closed. Bala earns 6.40 for backing you, and his 80 is free again. |
| 5.4a | Chapter 4, "Vote in a fund manager"; then "Your vote is in" and Bala's "Fund manager" tag | Vote yes | Chapter four is voting. Chitra suggests making Bala the circle's fund manager. A fund manager suggests how the pot is invested, and everyone still votes on each plan. You vote yes, and Bala gets the job. |
| 5.4b | "Vote on a rule"; then "The vote passed" | Vote yes | Then Bala suggests lowering the fee for leaving early from three percent to two. It passes with more than half of the six votes, and the new rule starts when the round closes. |
| 5.5a | Chapter 5, "Dev stops paying"; Dev's row marked behind | Continue | Chapter five is a member who stops paying. Dev borrowed 350 and has paid nothing back. |
| 5.5b | "Dev's loan was covered"; a bar of 350 fills: Dev 300, Chitra 30, Esha 20 | — | When the last round closes, the circle takes what he owes from his own savings first, which covers 300. Chitra vouched for him, so she covers the next 30. Esha backed him second, so she covers the last 20. |
| 5.5c | You, Bala and Farhan with "lost 0"; Dev's debt of 106.75 | — | You, Bala and Farhan did not back Dev, and you lose nothing. Dev leaves owing 106.75, and he can't join another circle until he pays it. |
| 5.6a | Chapter 6, "Collect your share-out"; then "Everyone was paid out" | Collect my share-out | Chapter six is the share-out. The circle has ended. Your share is your savings plus your part of what the circle earned, which is the interest paid on loans and 60 from investments. |
| 5.6b | Your payout, 712.04; then Farhan +14.08 and Bala +20.48; then Chitra −16.07 and Esha −6.02 | — | You collect 712. Farhan only saved, and he ends 14 ahead. Bala backed a loan that was repaid, and he ends 20 ahead. Chitra and Esha backed the loan that wasn't, and they end 16 and 6 behind. |

### Part 6. The real app
| # | Screen | Tap | Voiceover |
|---|---|---|---|
| 6.1 | "You did it", then Home | Continue | When the tutorial ends you are in the real app, on Avalanche's Fuji test network. |
| 6.2 | Create a circle: name, saving per round, number of rounds, round length | Create the circle | To create a circle, you give it a name, the amount each person saves per round, the number of rounds, and how long a round lasts. Creating it is one transaction. |
| 6.3 | "Invite people" and the share link; a second phone shows "You're invited" | Invite people, Join the circle | Then you invite people and share the link. A friend opens it, sees that they are invited, and joins. The circle starts once five people are in. |
| 6.4 | "Add practice members"; Gita, Hari, Indu and Jay appear, labelled as practice members | Add practice members | If you are trying it alone, add practice members and the app fills the seats. |
| 6.5 | "Suggest a change": make a member the fund manager; the vote; the "Fund manager" tag | Suggest, Vote yes | This is where the investing friend comes in. Suggest a member as fund manager, and the circle votes. |
| 6.6 | "Change the money plan": ready to lend, Aave, LP pool, cash, adding to 100% | Change the money plan | Once they are in, the manager can change the money plan: how much is ready to lend, how much goes to Aave, how much to the LP pool, and how much stays as cash. The group votes on every plan. |
| 6.7 | The pot's "Earned so far" going up as rounds close. Caption: "Test investments, sped up for the demo" | — | As rounds close, you can watch what the pot has earned. |
| 6.8 | "Back a loan request": "You could lose up to … · You earn …", with "Covers first" and "Covers second" | Back | When a friend asks for a loan, you can back it. Before you confirm, the app tells you in money what you could lose and what you will earn. You choose to cover first for the full rate, or second for half. |
| 6.9 | A result message with its explorer link; the transaction page on Snowtrace | Open the link | Every action is a transaction from your own wallet, and each one links to the public explorer, where anyone can check it. |

### Part 7. What it fixes
| # | On screen | Voiceover |
|---|---|---|
| 7.1 | The checklist from 1.4 returns | Back to the four problems. |
| 7.2 | Line 1 is ticked | Nobody can leave with the pot, because a contract holds it. |
| 7.3 | Line 2 is ticked | Nobody argues about who paid, because every payment is a public transaction. |
| 7.4 | Line 3 is ticked | The money earns between loans, because the circle invests it, led by the friend who knows how. |
| 7.5 | Line 4 is ticked; the six dots, three of them green | And a default stops at the borrower and the people who chose to back them. |

### Part 8. What this build is
| # | On screen | Voiceover |
|---|---|---|
| 8.1 | "Proof of concept · test money · simulated investments" | This is a proof of concept, built for a hackathon. The money is test money, and the investments are simulated and sped up. |
| 8.2 | "The promise covers defaults." | The promise covers defaults. If the investments lose value, all the members share that loss. |
| 8.3 | The factory contract address on Fuji | The contracts are deployed on Avalanche's Fuji test network. |

### Part 9. Close
| # | On screen | Voiceover |
|---|---|---|
| 9.1 | The Kuber wordmark and "Save your money together." | Kuber. Save your money together. |

## 4. Where the numbers come from
| Number | Source |
|---|---|
| "Lends 200" in Part 1 | An example amount, not a statistic |
| 350, 270, 80, 8%, 6.40, 300, 30, 20, 60 | SPEC §4 worked example and the tutorial's own step text (`services/dev-api/src/tutorial.ts`) |
| 712.04, +14.08, +20.48, −16.07, −6.02, debt 106.75 | SPRINT.md "End numbers" and SPEC §4 payout table. The video uses whatever the app shows if it differs. |
| 5 to 50 members, 90% borrow limit, 3% early-exit fee | PRD §6 |

## 5. What it needs
| Need | Status |
|---|---|
| Tutorial mode working end to end | Built; record once the screens stop changing |
| The real app on Fuji: create, share link, join, practice members, actions with explorer links | Built (commit M10) |
| Fund manager, money plan, visible earnings, backing risk | Built (commit M11). Recorded in Parts 5.4a and 6.5 to 6.8 |
| Indian names in the app: Bala, Chitra, Dev, Esha, Farhan | Done in the app; the real app's practice members are Gita, Hari, Indu and Jay |
| Narration audio | Voice approved; the clips are made with `~/voice/kuber/make.sh` |
| The submission's video rules (length limit, shape) | Not known yet |
