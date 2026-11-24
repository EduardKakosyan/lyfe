create table money_accounts (
    id uuid primary key,
    name text not null check (trim(name) <> ''),
    currency text not null check (currency ~ '^[A-Z]{3}$'),
    opening_minor bigint not null,
    spendable boolean not null default false
);

-- Amounts are signed minor units of the account currency. Opening balance
-- is the balance immediately before the earliest entry in this ledger.
create table money_entries (
    id uuid primary key,
    account_id uuid not null references money_accounts,
    posted_on date not null,
    description text not null,
    amount_minor bigint not null check (amount_minor <> 0),
    kind text not null check (kind in ('expense','refund','income','transfer')),
    category text,
    statement_ref text,
    unique (account_id, statement_ref),
    check ((kind in ('expense','refund')) = (category is not null)),
    check (category is null or trim(category) <> ''),
    check (kind = 'transfer' or (amount_minor < 0) = (kind = 'expense'))
);
create index money_entry_history on money_entries (account_id, posted_on desc);

create view money_monthly_spending as
select a.currency, date_trunc('month', e.posted_on::timestamp)::date as month,
       e.category, -sum(e.amount_minor) as net_minor
from money_entries e join money_accounts a on a.id = e.account_id
where e.kind in ('expense','refund')
group by a.currency, month, e.category;

create table money_bills (
    id uuid primary key,
    account_id uuid not null references money_accounts,
    description text not null,
    due_on date not null,
    amount_minor bigint not null check (amount_minor > 0),
    paid_on date
);

-- Count overdue unpaid bills too. Payday itself is outside the window.
-- NULL means no usable estimate; a negative result is a real shortfall.
create function money_until_payday(unit text, as_of date, payday date) returns numeric
language sql stable as $$
    select case when payday > as_of then
        (select sum(opening_minor) from money_accounts where currency = unit and spendable)
        + coalesce((select sum(e.amount_minor) from money_entries e
            join money_accounts a on a.id = e.account_id
            where a.currency = unit and a.spendable and e.posted_on <= as_of), 0)
        - coalesce((select sum(b.amount_minor) from money_bills b
            join money_accounts a on a.id = b.account_id
            where a.currency = unit and b.due_on < payday
              and (b.paid_on is null or b.paid_on > as_of)), 0)
    end
$$;
