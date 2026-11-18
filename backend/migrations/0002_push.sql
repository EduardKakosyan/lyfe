-- Step 2: push notifications.

-- Where Apple delivers notifications for a signed-in device. The token is
-- Apple's address for one install of the app, not a secret that grants
-- access to lyfe. `apns_environment` is the Apple service that accepted it
-- last ("development" or "production"); null until one has.
alter table device_sessions
    add column apns_token text,
    add column apns_environment text,
    add column apns_token_at timestamptz;

-- What has been sent, so a prompt goes out at most once for its period:
-- a day for "train today", a week (its Monday) for "recovery open".
create table notifications (
    id bigint generated always as identity primary key,
    kind text not null,
    period date not null,
    title text not null,
    body text not null,
    sent_at timestamptz not null default now(),
    unique (kind, period)
);
