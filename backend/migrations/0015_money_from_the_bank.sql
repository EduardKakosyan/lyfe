-- Money, imported: accounts and posted transactions come from SimpleFIN
-- Bridge once the owner has connected their banks there. The ledger of
-- 0012 was drawn for statements typed by hand and never held a row; it is
-- replaced by one shaped like what the bank sends.

drop function money_until_payday(text, date, date);
drop view money_monthly_spending;
drop table money_bills;
drop table money_entries;
drop table money_accounts;

-- One sign-in at one bank, as the bridge names it. `problem` is what the
-- bridge last said is wrong with it, in its own words, and null while it
-- works; `problem_since` is the day that started, so the owner is told
-- once for each time it breaks.
create table money_connections (
    id text primary key,
    name text not null,
    problem_code text,
    problem text,
    problem_since date,
    seen_at timestamptz not null default now(),
    check ((problem is null) = (problem_code is null)),
    check ((problem is null) = (problem_since is null))
);

-- An account under a connection. The balance is the bank's own figure at
-- `balance_at`, in minor units of the account's currency; a card that is
-- owed on is negative. An account the owner has set aside (savings,
-- investments) keeps its balance on show and its movements out of spending.
create table money_accounts (
    id uuid primary key default gen_random_uuid(),
    connection_id text not null references money_connections,
    provider_id text not null,
    name text not null check (trim(name) <> ''),
    currency text not null check (currency ~ '^[A-Z]{3}$'),
    balance_minor bigint not null,
    available_minor bigint,
    balance_at timestamptz not null,
    set_aside boolean not null default false,
    problem text,
    seen_at timestamptz not null default now(),
    unique (connection_id, provider_id)
);

-- One posted transaction. The bank's id is unique within its account, so
-- importing the same days again refreshes a row instead of adding one.
-- `day` is the day it counts on, in the owner's time zone: when it
-- happened where the bank says, otherwise when it posted.
--
-- What it is: money spent (an expense), money back for something spent (a
-- refund, counted against its category), money in (income), or money moved
-- between the owner's own accounts (a transfer, which is never spending).
-- `sorted_by` says who decided: the owner for this one entry, a rule the
-- owner set for its payee, a match with the other half of a transfer, or
-- nobody yet (auto).
create table money_entries (
    id uuid primary key default gen_random_uuid(),
    account_id uuid not null references money_accounts,
    provider_id text not null,
    day date not null,
    posted_at timestamptz not null,
    amount_minor bigint not null check (amount_minor <> 0),
    payee text not null default '',
    description text not null default '',
    memo text not null default '',
    payee_key text not null default '',
    kind text not null check (kind in ('expense', 'refund', 'income', 'transfer')),
    category text check (category is null or trim(category) <> ''),
    sorted_by text not null default 'auto' check (sorted_by in ('auto', 'match', 'rule', 'owner')),
    peer_id uuid references money_entries on delete set null,
    first_seen_at timestamptz not null default now(),
    unique (account_id, provider_id),
    check (kind = 'transfer' or (amount_minor < 0) = (kind = 'expense')),
    check (category is null or kind in ('expense', 'refund')),
    check (kind <> 'refund' or category is not null),
    check ((peer_id is not null) = (sorted_by = 'match'))
);
create index money_entries_day on money_entries (day desc);

-- What the owner said a payee is, once: it then holds for every entry
-- from that payee, past and to come, that the owner has not sorted by
-- itself.
create table money_rules (
    payee_key text primary key check (payee_key <> ''),
    kind text not null check (kind in ('spending', 'income', 'transfer')),
    category text,
    set_at timestamptz not null default now(),
    check ((kind = 'spending') = (category is not null))
);

-- What the bridge said about the whole import rather than one connection
-- or account, such as a warning about asking too often.
create table money_notes (
    id boolean primary key default true check (id),
    notes text[] not null default '{}'
);
insert into money_notes default values;
