-- What the investments are in, what everything comes to over time, and what
-- the way to financial independence is worked out from.

-- The bank lists what this account holds, so it is an investment account:
-- its balance is invested, not money in the bank. A fact from the bank,
-- kept apart from `set_aside`, which is the owner's to say.
alter table money_accounts add column invested boolean not null default false;

-- One thing an investment account holds, as the bridge lists it: a fund or
-- a share, how many of it, what they are worth now and, where the bank
-- says, what was paid for them. Amounts are minor units of `currency`;
-- shares are in millionths, since funds are held in fractions, and zero
-- when the bank does not say. The list is the account as it is now: a
-- holding the bridge no longer lists was sold, and its row goes.
create table money_holdings (
    account_id uuid not null references money_accounts on delete cascade,
    provider_id text not null,
    symbol text not null default '',
    name text not null default '',
    currency text not null check (currency ~ '^[A-Z]{3}$'),
    shares_micro bigint not null default 0 check (shares_micro >= 0),
    value_minor bigint not null,
    cost_minor bigint check (cost_minor is null or cost_minor > 0),
    seen_at timestamptz not null default now(),
    primary key (account_id, provider_id)
);

-- An account's balance on a day, as lyfe last saw it that day. The bridge
-- gives only the balance now, so what everything came to on an earlier day
-- is known only from the day this started being kept.
create table money_balances (
    account_id uuid not null references money_accounts on delete cascade,
    day date not null,
    balance_minor bigint not null,
    primary key (account_id, day)
);

-- What the owner assumes when lyfe works out how far off financial
-- independence is. Rates are in hundredths of a percent. The withdrawal
-- rate is the share of what is set aside that can be spent each year for
-- good; the return is growth above inflation, so every figure is in
-- today's money. The birth year is only for saying an age, and is missing
-- until the owner gives it.
create table money_plan (
    id boolean primary key default true check (id),
    withdrawal_bp integer not null default 350 check (withdrawal_bp between 200 and 600),
    return_bp integer not null default 400 check (return_bp between 0 and 1000),
    birth_year integer check (birth_year between 1900 and 2100),
    coast_age integer not null default 65 check (coast_age between 40 and 80)
);
insert into money_plan default values;
