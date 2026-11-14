# Kuber — exact on-screen wording (for the video script)

Taken from the build deployed on 2026-11-14. Names in angle brackets change with the member.

## People
- Tutorial practice members: **Bala, Chitra, Dev, Esha, Farhan**. Bala backs your loan; Dev borrows and stops paying; Chitra and Esha back Dev and lose 30 and 20; Farhan only saves.
- Real-app practice members: **Gita, Hari, Indu, Jay**, tagged "Practice member".

## Welcome and sign-up
- Tagline: "Save your money together."
- Buttons: "Sign in", "Try the tutorial".
- Sign-up: "Choose a display name" → "Continue" → "Verify me (test only — no real ID needed)" → "20,000 test mUSDC in your wallet" → "Start the tutorial".
- Text on the last sign-up screen: "Next, a short tutorial on a practice circle. Finish it once to open the app."

## Tutorial
- Banner on the first run: "Finish the tutorial to open the app". After the first finish: "Leave tutorial".
- First step: a choice, "Join a circle" or "Create a circle".
- Steps in order (join path): Allow your savings · Join the circle · Round 1 closes · Your money at work · Save round 3 early · Ask for a loan · Allow your repayments · Take your loan · Repay, part 1 · Repay, part 2 · **Vote in a fund manager** · Vote on a rule · Dev stops paying · Collect your share-out · You did it.
- Buttons: "Allow 700.00 mUSDC", "Join the circle", "Pay 100.00 mUSDC now", "Ask for 350.00 mUSDC", "Allow 800.95 mUSDC", "Take 350.00 mUSDC", "Pay 282.25 mUSDC", "Vote yes", "Continue", "Collect my share-out".
- Borrow step row: "Bala's risk for backing you: Bala could lose up to 80.00 · Bala earns 6.40".
- Fund-manager step: title "Vote in a fund manager", button "Vote yes"; result card "Your vote is in" with the row "Fund manager: None → Bala, when round 6 closes". Chitra proposes Bala; his fee is 0%.
- Each action shows "Sending…" → "Confirming…" → "Done — confirmed in block N" with a tappable hash. The "What just changed" card lists the server's transactions under "On the chain".
- "History (N)" in the guide panel lists every transaction you sent.
- End numbers: you 712.04; Bala 720.48; Chitra 683.93; Dev 0, still owing 106.75; Esha 693.98; Farhan 714.08.

## After the tutorial
- "What next?" screen: "Create your circle", "Join a circle", "Go to Home".
- Top bar switch: "Tutorial mode". One-time tip: "Want to try a feature again with test money? Turn on Tutorial mode any time." with "Got it".
- Chapter picker: heading "What do you want to try?"; six chapters; "Continue where I left off"; "Start from the beginning"; progress "Getting the practice circle ready… step N of M".

## Real app — Home and create
- Home: wallet card with the mUSDC balance, "Create a circle", "Add test money"; sections "Your circles", "Invited" (with "Join"), "Open circles".
- Create: "Circle name", saving per round, number of rounds, round length (2 minutes / 10 minutes / 1 hour / 1 day), starts in, members; "Rules" (collapsed); button "Create the circle"; then "Open the circle".
- Forming circle: "Add practice members", "Share the circle link", "Invite people" with a name field and "Add"; an unregistered name shows "<name> is not on Kuber yet" and "Invite them".

## Real app — circle page
- Actions: "Save now", "Borrow", "Back", "Repay", "Vote yes", "Suggest a change", "Leave", "Collect".
- Fund manager line: "Fund manager: Gita · 1 round managed · +0.50% a round on average". With none: "Fund manager: none. The group picks the money plan together."
- Member tags: "Fund manager", "Practice member".
- "Suggest a change" → part "Fund manager": "Member" picker, button "Make Gita the fund manager" ("Make yourself the fund manager" if you pick yourself), link "Remove the fund manager". Part "A rule": includes "Fund manager's fee (up to 10%)"; button "Suggest this change".
- Vote titles: "Make Gita the fund manager"; "New money plan: ready to lend 40%, Aave 35%, LP pool 15%, cash 10%".
- Money plan box: title "Money plan"; line "Ready to lend 40% · Aave 30% · LP pool 20% · Cash 10%"; button "Change the money plan" (manager only); for everyone else "Only the fund manager, Gita, can suggest a new money plan. Everyone still votes on it."
- When the manager is a practice member: "Gita will suggest a new plan. A little safer: ready to lend 40%, Aave 35%, LP pool 15%, cash 10%." and the button "Ask Gita to propose a new money plan".
- "Change the money plan" screen: sections "The plan now" and "Your new plan"; fields "Ready to lend", "Aave", "LP pool", "Cash"; total line "Adds up to 100%." or "Adds up to 95%. It must be exactly 100%."; button "Suggest this money plan".
- Backing: choices "Vouch · Covers first, earns the full rate" and "Agree · Covers second, earns half"; risk line "You could lose up to 20.00 · You earn 1.60" (it follows the amount); button "Back".
- Borrowing: field "Interest you offer backers (0–30%)"; line "47.00 needs backers. A backer of all of it could lose up to 47.00 · earns 4.70 (10%)."; "Ask a practice member to back me".
- Pot card: "Earned so far", "Aave earned 0.08 this round", "LP pool up 0.09 this round" (or "LP pool down … this round").
- Activity lines, each with its hash: "You proposed: make Gita the fund manager", "Gita is now the fund manager", "Gita proposed: a new money plan (…)", "The money plan changed: …".
- "On the chain": the circle's contract address and "View on Snowtrace".
- Tapping any hash opens "Transaction details": what happened, status, when, block, from, to, gas used, "What was called", the events, and "View on Snowtrace".

## Good to know when recording
- A member can suggest only one change per round. After "Make Gita the fund manager", wait for the next round before suggesting something else.
- A proposal takes effect when its round closes. With 2-minute rounds: propose the manager in one round, see the tag in the next, ask for the money plan then, and see it applied the round after.
- To show a backed loan, ask for a little more than your own limit (for example 290 when the limit is 270).
- "Earned so far" grows a little every round; in testing it reached about 8 to 12 mUSDC by round 5 or 6.
- Suggesting a change needs 3 rounds of savings first.
