create extension if not exists pgcrypto;
create table plaid_connections (
    id uuid primary key default gen_random_uuid(),
    source text not null check (length(source) > 0),
    environment text not null,
    link_secret bytea,
    access_secret bytea,
    cursor text,
    accounts jsonb not null default '[]',
    holdings jsonb not null default '[]',
    synced_at timestamptz,
    unique (environment, source)
);
create table plaid_transactions (
    connection uuid references plaid_connections on delete cascade,
    transaction_id text not null,
    data jsonb not null,
    primary key (connection, transaction_id)
);
