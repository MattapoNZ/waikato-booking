-- Step 5: copy customers into Matt's Google Contacts (which then sync to his phone).
-- Paste into the Supabase SQL Editor and Run once. Safe to run again.
-- Uses the same Google connection as the calendar copy (gcal_token / gcal_http). It adds the "contacts" permission
-- to the Connect Google button, so you DISCONNECT and CONNECT Google once afterwards (Messages tab) to approve it.
-- Nothing is copied until you switch it on in the Messages tab.

-- 1. where each customer's Google contact is tracked
alter table customers add column if not exists gcontact_resource text;          -- Google's id for the contact, e.g. people/c123
alter table customers add column if not exists gcontact_dirty boolean not null default true;   -- needs copying
alter table customers add column if not exists gcontact_tries int not null default 0;
alter table customers add column if not exists gcontact_error text;

create table if not exists gcontacts_state (
  id int primary key default 1 check (id = 1),
  enabled boolean not null default false,
  group_resource text,             -- the "Waikato Interlocks" label in Google Contacts
  last_sync_at timestamptz,
  last_error text
);
insert into gcontacts_state (id) values (1) on conflict do nothing;
alter table gcontacts_state enable row level security;
drop policy if exists staff_all on gcontacts_state;
create policy staff_all on gcontacts_state for all using (is_staff()) with check (is_staff());

-- 2. any change to name / mobile / email / vehicle / install / subsidy marks the contact for re-copying
create or replace function customers_gcontact_mark() returns trigger language plpgsql as $$
begin
  if TG_OP = 'INSERT' or (NEW.first_name, NEW.last_name, NEW.mobile, NEW.email, NEW.vehicle, NEW.install_date, NEW.subsidised)
       is distinct from (OLD.first_name, OLD.last_name, OLD.mobile, OLD.email, OLD.vehicle, OLD.install_date, OLD.subsidised) then
    NEW.gcontact_dirty := true; NEW.gcontact_tries := 0; NEW.gcontact_error := null;
  end if;
  return NEW;
end $$;
drop trigger if exists gcontact_mark on customers;
create trigger gcontact_mark before insert or update on customers for each row execute function customers_gcontact_mark();

-- 3. ask Google for contacts permission as well as calendar (only changes the scope list of the existing connect link)
do $$
declare d text := pg_get_functiondef('gcal_auth_url'::regproc);
begin
  if d !~ 'auth/contacts' then
    d := replace(d, 'https://www.googleapis.com/auth/calendar.events''', 'https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/contacts''');
    if d !~ 'auth/contacts' then raise exception 'Could not add the contacts permission to gcal_auth_url — nothing changed'; end if;
    execute d;
  end if;
end $$;

-- 4. the copier: runs every minute, a few customers at a time
create or replace function gcontacts_sync(p_max int default 10) returns int
language plpgsql security definer set search_path = public as $$
declare st gcontacts_state; tok text; c customers; r jsonb; b jsonb; person jsonb; done int := 0; res text; code int;
  bodyj jsonb;
begin
  select * into st from gcontacts_state where id = 1;
  if not coalesce(st.enabled, false) then return 0; end if;
  if not exists (select 1 from customers where gcontact_dirty and gcontact_tries < 5) then return 0; end if;
  begin tok := gcal_token(); exception when others then
    update gcontacts_state set last_error = 'Google not connected: ' || sqlerrm where id = 1; return 0; end;
  if tok is null then update gcontacts_state set last_error = 'Google not connected' where id = 1; return 0; end if;

  -- the "Waikato Interlocks" label, made once
  if st.group_resource is null then
    r := gcal_http('POST', 'https://people.googleapis.com/v1/contactGroups', tok, 'application/json',
                   jsonb_build_object('contactGroup', jsonb_build_object('name', 'Waikato Interlocks'))::text);
    bodyj := case jsonb_typeof(r->'body') when 'string' then (r->>'body')::jsonb else r->'body' end;
    if (r->>'status')::int between 200 and 299 then
      update gcontacts_state set group_resource = bodyj->>'resourceName' where id = 1 returning * into st;
    elsif (r->>'status')::int = 403 then
      update gcontacts_state set last_error = 'Google said no: disconnect and connect Google again to allow contacts, and check the People API is switched on' where id = 1; return 0;
    end if;   -- other errors: carry on without the label
  end if;

  for c in select * from customers where gcontact_dirty and gcontact_tries < 5 and first_name not like '⛔%' order by created_at limit p_max loop
    person := jsonb_strip_nulls(jsonb_build_object(
      'names', jsonb_build_array(jsonb_build_object('givenName', c.first_name, 'familyName', c.last_name)),
      'phoneNumbers', case when c.mobile is not null then jsonb_build_array(jsonb_build_object('value', c.mobile, 'type', 'mobile')) end,
      'emailAddresses', case when c.email is not null then jsonb_build_array(jsonb_build_object('value', c.email)) end,
      'organizations', jsonb_build_array(jsonb_build_object('name', 'Waikato Interlocks customer', 'title', c.vehicle)),
      'biographies', jsonb_build_array(jsonb_build_object('value', concat_ws(' · ', 'Interlock customer',
          case when c.install_date is not null then 'installed ' || to_char(c.install_date, 'DD Mon YYYY') end,
          case when c.subsidised then 'subsidised' end, c.vehicle), 'contentType', 'TEXT_PLAIN'))));
    res := c.gcontact_resource; code := null;
    if res is not null then
      -- current etag is needed to update; 404 means it was deleted in Google, so make it again
      r := gcal_http('GET', 'https://people.googleapis.com/v1/' || res || '?personFields=metadata', tok, 'application/json', null);
      code := (r->>'status')::int;
      if code between 200 and 299 then
        bodyj := case jsonb_typeof(r->'body') when 'string' then (r->>'body')::jsonb else r->'body' end;
        r := gcal_http('PATCH', 'https://people.googleapis.com/v1/' || res || ':updateContact?updatePersonFields=names,phoneNumbers,emailAddresses,organizations,biographies',
                       tok, 'application/json', (person || jsonb_build_object('etag', bodyj->>'etag'))::text);
        code := (r->>'status')::int;
      elsif code = 404 then res := null;
      end if;
    end if;
    if res is null then
      if st.group_resource is not null then
        person := person || jsonb_build_object('memberships', jsonb_build_array(jsonb_build_object('contactGroupMembership', jsonb_build_object('contactGroupResourceName', st.group_resource))));
      end if;
      r := gcal_http('POST', 'https://people.googleapis.com/v1/people:createContact', tok, 'application/json', person::text);
      code := (r->>'status')::int;
      if code between 200 and 299 then
        bodyj := case jsonb_typeof(r->'body') when 'string' then (r->>'body')::jsonb else r->'body' end;
        res := bodyj->>'resourceName';
      end if;
    end if;
    if code between 200 and 299 then
      update customers set gcontact_resource = res, gcontact_dirty = false, gcontact_tries = 0, gcontact_error = null where id = c.id;
      done := done + 1;
    else
      update customers set gcontact_tries = gcontact_tries + 1, gcontact_error = 'Google ' || coalesce(code::text, '?') || ': ' || left(coalesce(r->'body'->'error'->>'message', r->>'body', ''), 200) where id = c.id;
      if code in (401, 403) then
        update gcontacts_state set last_error = 'Google said no (' || code || '): disconnect and connect Google again to allow contacts, and check the People API is switched on' where id = 1;
        exit;
      end if;
      if code = 429 then exit; end if;   -- too fast: try again next minute
    end if;
  end loop;
  update gcontacts_state set last_sync_at = now(), last_error = case when done > 0 then null else last_error end where id = 1;
  return done;
end $$;
revoke execute on function gcontacts_sync(int) from public, anon, authenticated;

-- 5. for the run sheet's Messages tab
create or replace function gcontacts_status() returns jsonb language sql stable security definer set search_path = public as $$
  select case when not is_staff() then null else jsonb_build_object(
    'enabled', s.enabled, 'last_sync_at', s.last_sync_at, 'last_error', s.last_error, 'labelled', s.group_resource is not null,
    'synced', (select count(*) from customers where gcontact_resource is not null and not gcontact_dirty),
    'waiting', (select count(*) from customers where gcontact_dirty and gcontact_tries < 5 and first_name not like '⛔%'),
    'failed', (select count(*) from customers where gcontact_dirty and gcontact_tries >= 5),
    'sample_error', (select gcontact_error from customers where gcontact_error is not null order by gcontact_tries desc limit 1)) end
  from gcontacts_state s where s.id = 1
$$;
create or replace function gcontacts_set(p_on boolean, p_retry boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'Staff only'; end if;
  update gcontacts_state set enabled = p_on, last_error = null where id = 1;
  if p_retry then update customers set gcontact_dirty = true, gcontact_tries = 0, gcontact_error = null; end if;
end $$;
revoke execute on function gcontacts_status() from public, anon; grant execute on function gcontacts_status() to authenticated;
revoke execute on function gcontacts_set(boolean, boolean) from public, anon; grant execute on function gcontacts_set(boolean, boolean) to authenticated;

-- 6. every minute, up to 10 customers (89 customers ≈ 9 minutes the first time)
select cron.unschedule('waikato-contacts') where exists (select 1 from cron.job where jobname = 'waikato-contacts');
select cron.schedule('waikato-contacts', '* * * * *', 'select gcontacts_sync(10)');
