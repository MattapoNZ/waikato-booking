-- Step 4: customer activity log, device records, and password + new-device checks.
-- Paste into the Supabase SQL Editor and Run once. Safe to run again.
-- Nothing here changes existing tables or functions: it only ADDS a log table, a devices table,
-- three small functions, and logging triggers. Every trigger swallows its own errors,
-- so logging can never stop a booking, payment or profile change from saving.

-- ---------- 1. activity log ----------
create table if not exists customer_events (
  id bigserial primary key,
  at timestamptz not null default now(),
  customer_id uuid references customers(id) on delete cascade,
  user_id uuid,                -- the login that did it (null = system job)
  kind text not null,          -- e.g. bookings_insert, customers_update, signed_in, password_set
  actor text,                  -- 'customer', 'staff: <name>' or 'system'
  method text,                 -- sign-in method of that session: otp, oauth, password …
  detail jsonb not null default '{}',
  device_id text, user_agent text, ip text
);
create index if not exists customer_events_cust_idx on customer_events (customer_id, at desc);
alter table customer_events enable row level security;
drop policy if exists staff_all on customer_events;
create policy staff_all on customer_events for all using (is_staff()) with check (is_staff());

-- who / what / where for the current request
create or replace function req_info() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare h json; m text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  select string_agg(distinct x->>'method', ',') into m from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) x;
  return jsonb_build_object(
    'actor', case when is_staff() then 'staff: ' || coalesce((select name from staff where auth_user_id = auth.uid()), '?')
                  when auth.uid() is not null then 'customer' else 'system' end,
    'method', m,
    'device', h->>'x-device-id',
    'ua', left(h->>'user-agent', 300),
    'ip', nullif(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for', ''), ',', 1), ''));
end $$;

-- generic logging trigger: inserts, deletes, and updates (only the fields that changed)
create or replace function log_row_event() returns trigger language plpgsql security definer set search_path = public as $$
declare n jsonb; o jsonb; ch jsonb; det jsonb; cid text; r jsonb;
begin
  begin
    n := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
    o := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
    cid := case when TG_TABLE_NAME = 'customers' then coalesce(n, o)->>'id' else coalesce(n, o)->>'customer_id' end;
    if TG_OP = 'UPDATE' then
      select jsonb_object_agg(key, jsonb_build_object('from', o->key, 'to', value)) into ch
        from jsonb_each(n) where o->key is distinct from value and key not in ('updated_at', 'last_seen_at');
      if ch is null then return null; end if;
      det := jsonb_build_object('id', n->'id', 'changed', ch);
    else
      det := coalesce(n, o);
    end if;
    if pg_column_size(det) > 8000 then det := jsonb_build_object('id', coalesce(n, o)->'id', 'note', 'too large to keep in full'); end if;
    r := req_info();
    insert into customer_events (customer_id, user_id, kind, actor, method, detail, device_id, user_agent, ip)
    values (cid::uuid, auth.uid(), TG_TABLE_NAME || '_' || lower(TG_OP), r->>'actor', r->>'method', det, r->>'device', r->>'ua', r->>'ip');
  exception when others then null;   -- never block the real change
  end;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['customers','bookings','payments','price_requests','service_requests','callout_requests',
                           'customer_vehicles','customer_credits','bills','enquiries']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists log_activity on %I', t);
      execute format('create trigger log_activity after insert or update or delete on %I for each row execute function log_row_event()', t);
    end if;
  end loop;
end $$;

-- the app logs a few things the tables can't see (signing in, setting a password)
create or replace function log_event(p_kind text, p_detail jsonb default '{}') returns void
language plpgsql security definer set search_path = public as $$
declare r jsonb := req_info();
begin
  if auth.uid() is null then return; end if;
  if p_kind not in ('signed_in', 'signed_out', 'password_set', 'new_device_code_sent', 'new_device_confirmed') then raise exception 'unknown event'; end if;
  insert into customer_events (customer_id, user_id, kind, actor, method, detail, device_id, user_agent, ip)
  values ((select id from customers where auth_user_id = auth.uid() limit 1), auth.uid(), p_kind, r->>'actor', r->>'method',
          coalesce(p_detail, '{}') - 'password', r->>'device', r->>'ua', r->>'ip');
end $$;
revoke execute on function log_event(text, jsonb) from public, anon;
grant execute on function log_event(text, jsonb) to authenticated;

-- ---------- 2. devices ----------
create table if not exists customer_devices (
  user_id uuid not null,
  device_id text not null,
  customer_id uuid references customers(id) on delete cascade,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  trusted boolean not null default false,
  trusted_by text,              -- how it was confirmed: otp, oauth …
  user_agent text, ip text,
  primary key (user_id, device_id)
);
alter table customer_devices enable row level security;
drop policy if exists staff_all on customer_devices;
create policy staff_all on customer_devices for all using (is_staff()) with check (is_staff());

-- Called by the app on every open. Records the device; a session that was confirmed by a code or by Google
-- (anything but a bare password) marks the device as trusted. A password-only session can NOT trust a device.
create or replace function device_check(p_device text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb := req_info(); meths text[]; strong boolean; was boolean; tr boolean; cid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if coalesce(length(p_device), 0) < 8 or length(p_device) > 80 then raise exception 'Bad device id'; end if;
  select array_agg(x->>'method') into meths from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) x;
  -- no amr in the token at all: we can't tell how they signed in, so don't lock them out
  strong := meths is null or exists (select 1 from unnest(meths) m where m <> 'password');
  select id into cid from customers where auth_user_id = auth.uid() limit 1;
  select trusted into was from customer_devices where user_id = auth.uid() and device_id = p_device;
  insert into customer_devices as d (user_id, device_id, customer_id, trusted, trusted_by, user_agent, ip)
  values (auth.uid(), p_device, cid, strong, case when strong then array_to_string(meths, ',') end, r->>'ua', r->>'ip')
  on conflict (user_id, device_id) do update set last_seen = now(), customer_id = coalesce(excluded.customer_id, d.customer_id),
    user_agent = excluded.user_agent, ip = excluded.ip,
    trusted = d.trusted or excluded.trusted, trusted_by = coalesce(d.trusted_by, excluded.trusted_by)
  returning trusted into tr;
  if was is null then
    insert into customer_events (customer_id, user_id, kind, actor, method, detail, device_id, user_agent, ip)
    values (cid, auth.uid(), 'device_new', r->>'actor', r->>'method', jsonb_build_object('trusted', tr), p_device, r->>'ua', r->>'ip');
  elsif not was and tr then
    insert into customer_events (customer_id, user_id, kind, actor, method, detail, device_id, user_agent, ip)
    values (cid, auth.uid(), 'new_device_confirmed', r->>'actor', r->>'method', '{}', p_device, r->>'ua', r->>'ip');
  end if;
  return jsonb_build_object('trusted', tr, 'strong', strong, 'new', was is null);
end $$;
revoke execute on function device_check(text) from public, anon;
grant execute on function device_check(text) to authenticated;
