-- Step 6: GST receipts (tax invoices) for every payment.
-- Paste into the Supabase SQL Editor and Run once. Safe to run again.
-- Every payment gets a numbered receipt. Emailing them is OFF until you switch it on in the run sheet's Messages tab,
-- and only payments taken after that are emailed. Customers can see all their receipts in the app.

create table if not exists receipt_settings (
  id int primary key default 1 check (id = 1),
  email_on boolean not null default false,
  business_name text not null default 'Waikato Interlocks Limited',
  gst_number text not null default '131-836-007',
  contact text not null default 'Matt · 027 264 6986 · waikatointerlocks@gmail.com'
);
insert into receipt_settings (id) values (1) on conflict do nothing;
alter table receipt_settings enable row level security;
drop policy if exists staff_all on receipt_settings;
create policy staff_all on receipt_settings for all using (is_staff()) with check (is_staff());

create table if not exists receipts (
  no bigserial primary key,                 -- receipt / tax invoice number
  payment_id uuid unique,                   -- not a foreign key: the receipt stays (as void) if the sale is undone
  customer_id uuid,
  booking_id uuid,
  issued_at timestamptz not null default now(),
  method text,
  lines jsonb,                              -- [{ name, qty, each_cents, cents }]
  total_cents int,
  gst_cents int,
  status text not null default 'pending',   -- pending (to email) · sent · no_email · not_sent · void
  to_email text,
  emailed_at timestamptz,
  voided_at timestamptz
);
do $$ begin if not exists (select 1 from receipts) then alter sequence receipts_no_seq restart with 1001; end if; end $$;   -- numbers start at 1001
create index if not exists receipts_customer_idx on receipts (customer_id, issued_at desc);
alter table receipts enable row level security;
drop policy if exists staff_all on receipts;
create policy staff_all on receipts for all using (is_staff()) with check (is_staff());

-- what was sold, worked out from the booking + the extras saved with the payment
create or replace function receipt_lines(p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p payments; b bookings; out jsonb := '[]'; x jsonb; s services; sum_c int := 0; bl bills; c int; ref text;
begin
  select * into p from payments where id = p_payment;
  if p.id is null then return '[]'; end if;
  select * into b from bookings where id = p.booking_id;
  ref := coalesce(p.provider_ref, '');
  if ref like 'stripe:%' then                -- paid online from a bill
    select * into bl from bills where (booking_id = p.booking_id and p.booking_id is not null) or stripe_ref = substr(ref, 8) or stripe_session_id = substr(ref, 8)
      order by paid_at desc nulls last limit 1;
    if bl.id is not null then
      out := out || jsonb_build_array(jsonb_build_object('name', bl.description, 'qty', 1, 'each_cents', bl.amount_cents, 'cents', bl.amount_cents));
      sum_c := bl.amount_cents;
      if coalesce(bl.surcharge_cents, 0) > 0 then
        out := out || jsonb_build_array(jsonb_build_object('name', 'Card payment fee', 'qty', 1, 'each_cents', bl.surcharge_cents, 'cents', bl.surcharge_cents));
        sum_c := sum_c + bl.surcharge_cents;
      end if;
    end if;
  elsif b.id is not null then
    if not (coalesce((b.details->>'blank')::boolean, false) and b.price_cents = 0) then
      select * into s from services where id = b.service_id;
      out := out || jsonb_build_array(jsonb_build_object('name',
        case when coalesce((b.details->>'install')::boolean, false) then coalesce(s.name, b.service_id) || ' + first month'
             when coalesce((b.details->>'block')::boolean, false) then 'Blocked time'
             when coalesce((b.details->>'temporary')::boolean, false) then 'Temporary removal'
             else coalesce(s.name, b.service_id) end
        || ' — ' || to_char(b.session_date, 'DD Mon YYYY'), 'qty', 1, 'each_cents', b.price_cents, 'cents', b.price_cents));
      sum_c := b.price_cents;
    end if;
    -- extras added at checkout: 'extras:vr,admin' or 'extras2:[ "vr", {"n":"Labour","q":1.5,"p":100} ]'
    if ref like 'extras:%' then
      for x in select to_jsonb(t) from unnest(string_to_array(substr(ref, 8), ',')) t where t <> '' loop
        select * into s from services where id = x #>> '{}';
        out := out || jsonb_build_array(jsonb_build_object('name', coalesce(s.name, x #>> '{}'), 'qty', 1, 'each_cents', coalesce(s.price_cents, 0), 'cents', coalesce(s.price_cents, 0)));
        sum_c := sum_c + coalesce(s.price_cents, 0);
      end loop;
    elsif ref like 'extras2:%' then
      for x in select * from jsonb_array_elements(substr(ref, 9)::jsonb) loop
        if jsonb_typeof(x) = 'string' then
          select * into s from services where id = x #>> '{}';
          out := out || jsonb_build_array(jsonb_build_object('name', coalesce(s.name, x #>> '{}'), 'qty', 1, 'each_cents', coalesce(s.price_cents, 0), 'cents', coalesce(s.price_cents, 0)));
          sum_c := sum_c + coalesce(s.price_cents, 0);
        else
          c := round((x->>'q')::numeric * (x->>'p')::numeric * 100);
          out := out || jsonb_build_array(jsonb_build_object('name', x->>'n', 'qty', (x->>'q')::numeric, 'each_cents', round((x->>'p')::numeric * 100), 'cents', c));
          sum_c := sum_c + c;
        end if;
      end loop;
    end if;
    if coalesce((b.details->>'credit_used_cents')::int, 0) > 0 then
      out := out || jsonb_build_array(jsonb_build_object('name', 'Account credit used', 'qty', 1, 'each_cents', -(b.details->>'credit_used_cents')::int, 'cents', -(b.details->>'credit_used_cents')::int));
      sum_c := sum_c - (b.details->>'credit_used_cents')::int;
    end if;
  end if;
  if jsonb_array_length(out) = 0 then
    out := jsonb_build_array(jsonb_build_object('name', 'Payment', 'qty', 1, 'each_cents', p.amount_cents, 'cents', p.amount_cents));
  elsif sum_c <> p.amount_cents then   -- anything that doesn't add up (e.g. a discount typed at the terminal) shows as its own line
    out := out || jsonb_build_array(jsonb_build_object('name', 'Adjustment', 'qty', 1, 'each_cents', p.amount_cents - sum_c, 'cents', p.amount_cents - sum_c));
  end if;
  return out;
exception when others then
  return jsonb_build_array(jsonb_build_object('name', 'Payment', 'qty', 1, 'each_cents', p.amount_cents, 'cents', p.amount_cents));
end $$;

-- every new payment gets a receipt; undoing the sale voids it
create or replace function payments_receipt() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if TG_OP = 'INSERT' then
      insert into receipts (payment_id, customer_id, booking_id, method, total_cents, gst_cents, status, issued_at)
      values (NEW.id, NEW.customer_id, NEW.booking_id, NEW.method, NEW.amount_cents, round(NEW.amount_cents * 3 / 23.0),
              case when (select email_on from receipt_settings where id = 1) then 'pending' else 'not_sent' end, coalesce(NEW.taken_at, now()))
      on conflict (payment_id) do nothing;
    elsif TG_OP = 'DELETE' then
      update receipts set status = 'void', voided_at = now() where payment_id = OLD.id;
    end if;
  exception when others then null;   -- a receipt problem must never stop a payment
  end;
  return null;
end $$;
drop trigger if exists receipt_make on payments;
create trigger receipt_make after insert or delete on payments for each row execute function payments_receipt();

-- receipts for payments already taken (history in the app; never emailed)
insert into receipts (payment_id, customer_id, booking_id, method, total_cents, gst_cents, status, issued_at)
select id, customer_id, booking_id, method, amount_cents, round(amount_cents * 3 / 23.0), 'not_sent', coalesce(taken_at, now())
from payments order by taken_at on conflict (payment_id) do nothing;

-- the receipt as plain text (for the email)
create or replace function receipt_text(p_no bigint) returns text language plpgsql stable security definer set search_path = public as $$
declare r receipts; st receipt_settings; c customers; l jsonb; t text; m text;
begin
  select * into r from receipts where no = p_no; select * into st from receipt_settings where id = 1; select * into c from customers where id = r.customer_id;
  m := case r.method when 'card_terminal' then 'EFTPOS' when 'online' then 'card online' when 'cash' then 'cash' when 'on_account' then 'on account (to pay later)' else coalesce(r.method, '') end;
  t := st.business_name || E'\nGST number ' || st.gst_number || E'\n\nTAX INVOICE / RECEIPT No. ' || r.no
    || E'\nDate: ' || to_char(r.issued_at at time zone 'Pacific/Auckland', 'DD Mon YYYY')
    || E'\nCustomer: ' || coalesce(nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), ''), '—') || E'\n\n';
  for l in select * from jsonb_array_elements(coalesce(r.lines, '[]')) loop
    t := t || (l->>'name') || case when (l->>'qty')::numeric <> 1 then ' (' || trim(to_char((l->>'qty')::numeric, 'FM999990.##')) || ' × $' || to_char((l->>'each_cents')::int / 100.0, 'FM999990.00') || ')' else '' end
      || E'\n    ' || case when (l->>'cents')::int < 0 then '-$' else '$' end || to_char(abs((l->>'cents')::int) / 100.0, 'FM999990.00') || E'\n';
  end loop;
  t := t || E'\nTotal (incl GST): $' || to_char(r.total_cents / 100.0, 'FM999990.00')
    || E'\nGST included: $' || to_char(r.gst_cents / 100.0, 'FM999990.00')
    || E'\nPaid by: ' || m
    || case when r.status = 'void' then E'\n\n*** THIS RECEIPT WAS CANCELLED ***' else '' end
    || E'\n\nThanks!\n' || st.contact || E'\nSee all your receipts in the app: https://book.waikatointerlocks.co.nz/book/';
  return t;
end $$;

-- every minute: fill in the lines, and email the ones waiting (a minute after payment, so checkout details are saved)
create or replace function receipts_run() returns int language plpgsql security definer set search_path = public as $$
declare r receipts; n int := 0; em text; st receipt_settings;
begin
  select * into st from receipt_settings where id = 1;
  update receipts set lines = receipt_lines(payment_id) where lines is null and status <> 'void' and payment_id is not null and issued_at < now() - interval '40 seconds';
  for r in select * from receipts where status = 'pending' and lines is not null and issued_at < now() - interval '40 seconds' order by no limit 20 loop
    if not st.email_on then update receipts set status = 'not_sent' where no = r.no; continue; end if;
    select nullif(trim(email), '') into em from customers where id = r.customer_id;
    if em is null then update receipts set status = 'no_email' where no = r.no; continue; end if;
    perform email_send(em, 'Your receipt No. ' || r.no || ' — Waikato Interlocks', receipt_text(r.no), 'receipt', r.customer_id);
    update receipts set status = 'sent', to_email = em, emailed_at = now() where no = r.no;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function receipts_run() from public, anon, authenticated;
select cron.unschedule('waikato-receipts') where exists (select 1 from cron.job where jobname = 'waikato-receipts');
select cron.schedule('waikato-receipts', '* * * * *', 'select receipts_run()');

-- run sheet: switch emailing on/off, email a receipt again (optionally to another address)
create or replace function receipts_set(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin if not is_staff() then raise exception 'Staff only'; end if; update receipt_settings set email_on = p_on where id = 1; end $$;
create or replace function receipt_email(p_no bigint, p_to text default null) returns text language plpgsql security definer set search_path = public as $$
declare r receipts; em text;
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  select * into r from receipts where no = p_no; if r.no is null then raise exception 'No such receipt'; end if;
  if r.lines is null then update receipts set lines = receipt_lines(payment_id) where no = p_no; end if;
  em := coalesce(nullif(trim(p_to), ''), (select nullif(trim(email), '') from customers where id = r.customer_id));
  if em is null then raise exception 'No email address for this customer'; end if;
  perform email_send(em, 'Your receipt No. ' || r.no || ' — Waikato Interlocks', receipt_text(r.no), 'receipt', r.customer_id);
  update receipts set to_email = em, emailed_at = now(), status = case when status = 'void' then 'void' else 'sent' end where no = p_no;
  return em;
end $$;
revoke execute on function receipts_set(boolean) from public, anon; grant execute on function receipts_set(boolean) to authenticated;
revoke execute on function receipt_email(bigint, text) from public, anon; grant execute on function receipt_email(bigint, text) to authenticated;

-- customer app: their own receipts
create or replace function my_receipts() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('settings', (select jsonb_build_object('business_name', business_name, 'gst_number', gst_number, 'contact', contact) from receipt_settings where id = 1),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('no', r.no, 'issued_at', r.issued_at, 'method', r.method, 'lines', coalesce(r.lines, receipt_lines(r.payment_id)),
      'total_cents', r.total_cents, 'gst_cents', r.gst_cents, 'void', r.status = 'void') order by r.no desc)
      from receipts r where r.customer_id = (select id from customers where auth_user_id = auth.uid() limit 1)), '[]'))
$$;
revoke execute on function my_receipts() from public, anon; grant execute on function my_receipts() to authenticated;
