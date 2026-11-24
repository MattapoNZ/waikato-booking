-- step8: reminders for unpaid bills (24 Nov 2026)
-- Each unpaid bill (e.g. a no-show fee) gets a reminder the morning after it was sent, then every 3 days,
-- at most 3 reminders. Email if we have one, otherwise a text. Includes the pay-online link.
-- Bills paid in person at the run sheet are marked paid there (status 'paid', stripe_ref 'in person'), so no reminder.
alter table public.bills add column if not exists reminded_at timestamptz;
alter table public.bills add column if not exists remind_count integer not null default 0;

create or replace function public.bills_remind() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0; v_amt text; v_body text;
begin
  for r in
    select x.id, x.token, x.description, x.amount_cents, x.customer_id, c.first_name, c.email, c.mobile
      from bills x join customers c on c.id = x.customer_id
     where x.status = 'sent' and x.remind_count < 3
       and coalesce(x.reminded_at, x.created_at) < now() - case when x.remind_count = 0 then interval '18 hours' else interval '3 days' end
  loop
    v_amt := to_char(r.amount_cents / 100.0, 'FM$999990.00');
    v_body := 'Hi ' || coalesce(nullif(trim(r.first_name), ''), 'there') || ', a reminder that ' || v_amt || ' is still owing for: ' || r.description
      || E'.\n\nPay online by card: ' || bill_link(r.token)
      || E'\n\nOr pay at your next visit. Questions? Text Matt on 027 264 6986.\nWaikato Interlocks';
    if coalesce(trim(r.email), '') <> '' then
      perform email_send(trim(r.email), 'Reminder: ' || v_amt || ' owing to Waikato Interlocks', v_body, 'bill', r.customer_id);
    elsif coalesce(trim(r.mobile), '') <> '' then
      perform sms_send(trim(r.mobile), v_body, 'bill', r.customer_id, v_body);
    else
      continue;
    end if;
    update bills set reminded_at = now(), remind_count = remind_count + 1 where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.bills_remind() from public, anon, authenticated;

-- every morning at 10:07am NZ summer time (9:07am in winter)
select cron.schedule('waikato-bill-reminders', '7 21 * * *', 'select public.bills_remind()');
