# lyfe

lyfe is a private app that keeps one person's routines going and shows them where their money went, what it all comes to, and how far off financial independence is.

## Language

**Training consistency**:
Following a planned exercise routine repeatedly over time, distinct from improvements in strength, endurance, or body composition.

**Streak**:
A count of consecutive periods in which a supporting routine was kept: weeks with four completed gym sessions, weeks with three completed breath-training sessions, or days on which a food log happened. Sessions count on whichever days they happen. A streak measures showing up; it is separate from progression.
_Avoid_: Daily gym streak, fixed-day streak

**Progression**:
Measured improvement in a capability, such as breath-hold time, which lyfe tracks from recorded results and actively pushes by setting the next step. Distinct from a streak: a hard session can break neither, and a kept streak does not imply progress.

**Recovery**:
Keeping a streak alive after a single missed period by completing the very next one. It never requires make-up sessions; two missed periods in a row end the streak.
_Avoid_: Catch-up, make-up session, streak freeze

**Weigh-in**:
A weight the owner types, normally into the morning prompt without opening lyfe. A day's weight is the last one typed that day. Not a streak: a missed morning costs nothing, and there is no second reminder.
_Avoid_: Weight streak, daily weight log

**Saved meal**:
A meal the owner eats repeatedly, defined once from its ingredients with the number of portions the recipe makes: typed as weighed from scratch, or saved from a meal that was built. Logging it is one tap. Its numbers are measured, except what a photo was estimated at, which stays estimated each time.
_Avoid_: Recipe (for the saved meal itself), favourite, template

**Part**:
One thing in a meal that is built rather than tapped: a packet scanned by its barcode with the grams eaten, a food typed by hand or picked from the catalogue, or a photo and one line. A meal is what its parts add up to, and each part is measured or estimated by itself.
_Avoid_: Item (that is a food a model saw in a photo), component, ingredient (that is what goes into a saved meal)

**Food log**:
The meals logged on a day, each under a part of the day: breakfast, lunch, dinner or snack. A meal is a saved meal tapped, or a meal built from parts. A main meal with nothing logged is unknown, never zero, so the day's total is only what was logged.
_Avoid_: Calorie count (for the log), diary

**Photo meal**:
A meal, or a part of one, logged with a photo and a one-line description, whose calories and protein a model estimates afterwards. It is sent to be estimated as soon as it is added, counts for the day once its meal is logged, and its figures join the total once estimated. The owner can correct each item's grams, say how much oil or sauce went in, or type the figures instead.
_Avoid_: AI meal, scanned meal

**Estimate**:
A photo meal's figures as the model judged them, always shown with a range either way. Estimated figures are kept apart from measured ones: a weighed ingredient, a label or figures typed by hand are measured, a photo is estimated, also as a part of a meal or an ingredient of a saved one.
_Avoid_: Guess (in the app), approximation

**Illustration**:
A meal photo redrawn on the Spark as the meal it shows: the food in its own colours, black ink outlines, and its dish in a Poster colour, shown in the photo's place once it is ready. It only ever adds to a meal: the meal counts without it, and the photo stays if it never comes.
_Avoid_: Filter, AI image, thumbnail, pictogram (that was the first look, which lost the meal)

**Macros**:
The grams of protein, carbs and fat in a food. A food can be typed as its macros alone, and what it comes to is then worked out at 4 kcal a gram of protein or carbs and 9 a gram of fat, the figures labels are worked out with. It is measured, not estimated.
_Avoid_: Macro calories (as something typed), nutrients

**Catalogue**:
The foods lyfe comes with, each with its figures per 100 g: twenty staples and the generic foods of the USDA database, browsed by category and searched by name. A food picked from it is weighed, so it is measured.
_Avoid_: Food database (that is the downloaded one barcodes are looked up in), library

**Icon**:
A small drawing of one food in the catalogue, drawn on the Spark from the food's name alone and kept. Every food's is drawn ahead of time, so none is waited for; one not drawn yet is shown by its category's.
_Avoid_: Emoji, stock image, thumbnail, illustration (that is a meal photo redrawn)

**Label**:
The calories and protein per 100 g printed on packaged food, found by its barcode in the downloaded food database or typed once by the owner. A meal logged from a label is measured.
_Avoid_: Nutrition facts (as a term in lyfe), product entry

**Target**:
The calories and protein the owner holds a day to. The owner sets it; lyfe shows each day against it and never changes it without the owner's approval. A target counts from the day it is set.
_Avoid_: Goal, budget, limit

**Seven-day average**:
The mean of the day's weights over the last seven days that have one, given once at least three do. It is the weight trend; a single morning's reading is not.
_Avoid_: Weight trend line (as a separate figure), moving average


**Bridge**:
SimpleFIN Bridge, the outside service the owner connects their banks to. It holds the bank sign-ins and hands lyfe a read-only view of the accounts. lyfe asks it; it never calls lyfe.
_Avoid_: Aggregator (as a term in lyfe), bank API, sync provider

**Connection**:
One sign-in at one bank, held at the bridge. It can break until the owner signs in again there; its accounts then stop updating and lyfe says so.
_Avoid_: Link, integration, login

**Entry**:
One posted transaction in an account, imported from the bank under the bank's own id for it, so importing it again never counts it twice. It is an expense, a refund, money in, or money moved. Pending transactions are not entries.
_Avoid_: Transaction (in the app), line item, charge

**Spending**:
Expenses less refunds over a month, in every everyday account together. Money moved between the owner's own accounts is never spending, so a card payment is not: the purchases it pays for already were.
_Avoid_: Outflow, total debits, burn

**Refund**:
Money back for something bought. It comes off the category it was bought under, not onto income.
_Avoid_: Credit, reversal, negative expense

**Money moved**:
The same money leaving one of the owner's accounts and arriving in another: a card payment, a transfer to savings. lyfe pairs the two halves by amount when both accounts are connected; otherwise the owner says so.
_Avoid_: Transfer (in the app), internal transaction, payment (for a card payment as if it were spending)

**Payee**:
Who an entry was paid to or came from, as the bank names it. The same shop is the same payee whatever branch number follows its name.
_Avoid_: Merchant, vendor, counterparty

**Sorting**:
The owner saying what an entry is: a category, money in, or money moved. Said once it holds for the payee, for every entry past and to come, unless the owner sorts one entry by itself. Until then the entry waits, and counts in the month as spending not sorted yet.
_Avoid_: Categorising, tagging, labelling, reviewing

**Category**:
One of twelve fixed kinds of spending an expense or refund is sorted into. The owner picks it; lyfe never guesses one.
_Avoid_: Tag, budget line, envelope

**Set aside**:
An account the owner has marked as savings or investments. Its balance is shown; nothing that moves in it counts as spending or waits to be sorted. Every other account is an everyday account. What is set aside is what counts towards financial independence.
_Avoid_: Hidden account, excluded account, savings (for the mark itself)

**Investment account**:
An account the bank lists holdings for. Its balance is invested, not money in the bank. That is the bank's to say, each time it is asked; whether the account is set aside is still the owner's, and it starts that way.
_Avoid_: Brokerage (as a term in lyfe), portfolio, trading account

**Holding**:
One thing an investment account is in: a fund or a share, with how many of it, what they are worth as the bank last priced them and, where the bank says, what was paid for them. The same fund in two accounts is one holding. lyfe looks no prices up.
_Avoid_: Position, stock (for a holding), asset, ticker (that is only its symbol)

**Net worth**:
Every account added up: what is in the bank and what is invested, less what is owed. Kept once a day from the day lyfe began keeping it, which is as far back as its line goes.
_Avoid_: Balance (that is one account's), wealth, total assets

**Whole month**:
A finished month that the entries lyfe holds reach back to the first day of. Only whole months are compared with or averaged over, the last twelve at most; the month still running never is one.
_Avoid_: Full month, complete month, closed month

**Kept**:
What came in less what was spent over the whole months counted. As a share of what came in it is the savings rate. It is measured from pay as it lands in the bank, so what is taken off before that is in neither figure.
_Avoid_: Saved (set aside is the mark on an account), surplus, cash flow

**Plan**:
What the owner assumes when lyfe works out the way to financial independence: the withdrawal rate, growth above inflation, the age to coast by, and their birth year. The owner sets it; lyfe never changes it. Everything worked out from it is in today's money.
_Avoid_: Settings, forecast, goal, target (that is food's)

**Withdrawal rate**:
The share of what is set aside that could be spent each year for good. Part of the plan.
_Avoid_: Safe withdrawal rate (nothing about it is certain), SWR, drawdown

**FI number**:
What would have to be set aside for the owner's spending to be covered for good: a year's spending divided by the withdrawal rate. Financial independence is having it. FIRE is the name of the screen that shows how far off that is.
_Avoid_: FIRE number, retirement goal, nest egg

**Coast number**:
What would have to be set aside today to grow to the FI number by a given age with nothing more added.
_Avoid_: Coast FIRE (as a figure), halfway point

**Runway**:
How many months of spending the money on hand would cover: what is in the bank less what is owed, over a month's spending.
_Avoid_: Emergency fund (lyfe does not know what the money is for), buffer, cushion (as a figure)
