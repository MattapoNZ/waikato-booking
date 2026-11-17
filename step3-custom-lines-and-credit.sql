-- Step 3: custom checkout lines (travel, labour, discounts), price changes, and account credit.
-- Paste into the Supabase SQL Editor and Run once. Safe to run again.
-- Custom lines and price changes need no new tables: they are saved on bookings.price_cents and bookings.details.

-- 1. "Other / custom sale" — a $0 placeholder service so a walk-in can be ONLY custom lines.
insert into services (id, name, duration_mins, price_cents, online_bookable)
values ('misc', 'Other / custom sale', 5, 0, false)
on conflict (id) do nothing;

-- 2. Account credit ledger. + = credit added, − = credit used at checkout or taken back. Balance = sum.
create table if not exists customer_credits (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  booking_id text,                         -- set when credit was used on a sale
  amount_cents int not null check (amount_cents <> 0),
  reason text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists customer_credits_customer_idx on customer_credits (customer_id);

alter table customer_credits enable row level security;
drop policy if exists staff_all on customer_credits;
create policy staff_all on customer_credits for all using (is_staff()) with check (is_staff());
-- Customers can see their own credit (for the app later)
drop policy if exists own_read on customer_credits;
create policy own_read on customer_credits for select
  using (customer_id in (select id from customers where auth_user_id = auth.uid()));
