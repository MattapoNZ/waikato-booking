-- Step 3: account credit for customers.
-- Paste into the Supabase SQL Editor and Run once. Safe to run again.
-- (Price changes and blank walk-in sales need nothing new: they use bookings.price_cents / bookings.details.)

-- Credit ledger. + = credit added, − = credit used at checkout or taken back. Balance = sum.
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
-- customers can see their own credit (for the app later)
drop policy if exists own_read on customer_credits;
create policy own_read on customer_credits for select
  using (customer_id in (select id from customers where auth_user_id = auth.uid()));
