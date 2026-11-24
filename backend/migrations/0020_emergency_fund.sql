-- What the owner keeps in savings for the unexpected. It is held back from
-- the savings set aside before they count towards financial independence
-- (ADR 0009), and is in the currency totals are in.
alter table money_plan
    add column emergency_fund_minor bigint not null default 0
    check (emergency_fund_minor between 0 and 10000000);

-- An investment account starts set aside. One imported before lyfe could
-- tell investment accounts apart was first seen as one after it already
-- existed, and was left as it was.
update money_accounts set set_aside = true where invested and not set_aside;
