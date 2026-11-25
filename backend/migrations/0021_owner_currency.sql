-- What currency an account is in is the bank's to say, unless the owner
-- says otherwise. A bridge can name the wrong one, and nothing is
-- converted, so an account said to be in the wrong one is left out of
-- every total. Everything that reads an account's currency reads the
-- owner's word where there is one.
alter table money_accounts rename column currency to bank_currency;
alter table money_accounts add column owner_currency text check (owner_currency ~ '^[A-Z]{3}$');
alter table money_accounts add column currency text not null
    generated always as (coalesce(owner_currency, bank_currency)) stored;

-- A holding the bank gives no currency for is in its account's, whichever
-- that is said to be. Until the next import says which those are, one in
-- its account's currency is taken to be such a one.
alter table money_holdings alter column currency drop not null;
update money_holdings h set currency = null
    from money_accounts a where a.id = h.account_id and h.currency = a.bank_currency;
