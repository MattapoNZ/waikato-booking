-- step7: no gaps after the online cutoff (24 Nov 2026)
-- Customers book the next time straight after the last booking. Online booking closes 2 hours before.
-- Before: once that next time was inside the 2 hours, the app jumped ahead to the first time 2 hours away
-- (e.g. last booking 11:10, customer at 9:25 got 11:25 confirmed) and left a gap.
-- Now: if the next time is inside the cutoff, the app won't confirm any later time. The customer can only
-- REQUEST that next time (pencilled, Matt confirms). Staff bookings (lead 0) and late requests (lead 15) are unchanged.
alter function public.next_slot(text, date, text, integer) rename to next_slot_raw;
revoke execute on function public.next_slot_raw(text, date, text, integer) from public, anon, authenticated;

create function public.next_slot(p_location text, p_date date, p_kind text default 'service', p_min_lead_mins integer default 120)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v integer; c integer;
begin
  v := next_slot_raw(p_location, p_date, p_kind, p_min_lead_mins);
  if p_kind is distinct from 'removal' and p_min_lead_mins > 15 then
    c := next_slot_raw(p_location, p_date, p_kind, 15);
    if c is distinct from v then return null; end if;   -- next time is inside the cutoff: request only
  end if;
  return v;
end $$;
revoke execute on function public.next_slot(text, date, text, integer) from public, anon;
grant execute on function public.next_slot(text, date, text, integer) to authenticated, service_role;
