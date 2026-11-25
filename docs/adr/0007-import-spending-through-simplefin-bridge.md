---
status: accepted
---

# Import spending through SimpleFIN Bridge

The owner wants one view of a month's spending by category across accounts held at more than one bank, and requires that the transactions arrive by themselves; importing files by hand was ruled out as the way it works. Plaid, the first provider tried, could not connect one of the owner's banks: its sign-in uses a second step Plaid does not support. SimpleFIN Bridge connected all three of the owner's institutions. lyfe will import through it: the owner connects each bank at the bridge, in a browser, and gives lyfe a one-time setup token, which lyfe trades for a read-only access address kept in a file on the Spark. The backend asks the bridge for balances and posted transactions every six hours and stores them in its own database; the phone reads them from the backend like everything else.

Polling keeps ADR 0004 whole: nothing calls in to the Spark. ADR 0002 put money after study because a provider could not be scheduled; it also said the order could be revisited once one was confirmed, and this is that.

What lyfe does with the transactions is decided here too, because the provider shapes it. Only posted transactions are imported, since pending ones change and vanish. lyfe does not guess categories: the owner says what a payee is once and that holds for the payee from then on. Money moved between the owner's own accounts is paired by amount and kept out of spending. The bridge gives no account type, so the owner marks savings as set aside; an account it lists holdings for is taken to be investments and starts that way. Nothing about money is stored on the phone.

## Consequences

- The bridge, and the aggregator it uses behind it, hold the bank sign-ins and see every balance and transaction. lyfe cannot narrow that; it is the price of automatic import, which the owner accepted when connecting the banks. Whether a bank's own terms mind its sign-in being given to an aggregator is the owner's call, not something lyfe can settle.
- The access address is a password to everything the bridge can read. It lives in one file on a shared machine, readable only by the `lyfe` account, outside the repository, the settings, the logs and the backup. Deleting the app's access at the bridge cuts lyfe off.
- Money is a day or two behind the cards: the bridge refreshes about once a day and banks post late. It is for looking back at a month, not for checking a purchase just made.
- The bridge allows about 24 requests a day and switches off an access that goes far past that. lyfe asks four times a day and never on demand from the phone, so there is no refresh button.
- Connections break when a bank wants signing in to again, and only the owner can mend one, at the bridge. lyfe can only say so, and prompts once each time.
- History starts where the bridge's does: the first import brought back about six months for some accounts and less for others. Earlier months are not there, and a month lyfe does not hold whole is never compared against.
- The bridge is a small paid subscription, and a single small provider. The bridge's client is one module and the entries it fills are not shaped by it beyond the bank's id for a transaction, so another source could fill the same tables.
- Sorting is by hand, once for each payee. It was chosen over a model's guess because a wrong category is worse than an unsorted one in a figure the owner is meant to trust; a model on the Spark suggesting a category is a later option.
- The two migrations that made and dropped the Plaid tables stay, as the database on the Spark has run them.

## Amended, 2026-11-25

"Nothing about money is stored on the phone" is not quite so. The phone keeps the last Home it was sent in a file (`home.json`, `HomeCache` in `apps/LyfeKit/Sources/LyfeKit/Store/Stores.swift`), so that Home can be shown offline with its age, and Home carries the money strip (`MoneyGlance` in `Money/Money.swift`, the `money` field of `HomeSnapshot`): the month, its currency, what has been spent in it so far, how many entries wait to be sorted, the first problem with the import, which can name a bank, and when the last import succeeded. The file is written with the protection that keeps it encrypted until the phone is first unlocked after a restart. MONTH, WORTH and FIRE themselves are fetched when they are opened and held only in memory while lyfe runs.
