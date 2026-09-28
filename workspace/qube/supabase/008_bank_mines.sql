-- QÜBE: the central bank, and richer mines.
-- Run once, after 007. SQL Editor → New query → paste → Run.
--
-- Points spent at the Hexa no longer vanish: every purchase moves them from the
-- member's wallet to the central bank. Total supply = points in wallets + the bank.
-- Mines now pay 5 points a day each, so every mine added to an Industrial Square
-- adds 5 more.

-- ============================================================ the central bank

create table if not exists public.bank_ledger (
  id           bigint generated always as identity primary key,
  amount       bigint not null,
  kind         text not null check (kind in ('purchase')),
  note         text,
  source_user  uuid references public.profiles (id) on delete set null,
  ledger_id    bigint unique,   -- the member's ledger row this came from
  created_at   timestamptz not null default now()
);
create index if not exists bank_ledger_created_idx on public.bank_ledger (created_at);
alter table public.bank_ledger enable row level security;
-- No policies: the bank's totals are public through points_stats().

-- Every spend in a member's ledger lands in the bank, in the same transaction.
create or replace function public.bank_receive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.bank_ledger (amount, kind, note, source_user, ledger_id, created_at)
  values (-new.amount, 'purchase', new.note, new.user_id, new.id, new.created_at);
  return new;
end;
$$;

drop trigger if exists ledger_to_bank on public.ledger;
create trigger ledger_to_bank
  after insert on public.ledger
  for each row when (new.kind = 'spend' and new.amount < 0)
  execute function public.bank_receive();

-- Everything spent before the bank opened goes into it now.
insert into public.bank_ledger (amount, kind, note, source_user, ledger_id, created_at)
select -l.amount, 'purchase', l.note, l.user_id, l.id, l.created_at
from public.ledger l
where l.kind = 'spend' and l.amount < 0
on conflict (ledger_id) do nothing;

-- ============================================================ mines: 5 points a day each

create or replace function public.mine_rate() returns integer language sql immutable as $$ select 5 $$;

create or replace function public.collect_mines()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_total integer := 0;
  s record;
  v_days integer;
begin
  if v_uid is null then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('mines:' || v_uid::text));
  for s in
    select "row", col, mines, last_collected_at from public.squares
    where owner = v_uid and kind = 'industrial' and last_collected_at <= now() - interval '1 day'
    for update
  loop
    v_days := floor(extract(epoch from (now() - s.last_collected_at)) / 86400)::integer;
    update public.squares set last_collected_at = s.last_collected_at + v_days * interval '1 day'
    where "row" = s."row" and col = s.col;
    v_total := v_total + v_days * s.mines * public.mine_rate();
  end loop;
  if v_total > 0 then
    insert into public.ledger (user_id, amount, kind, note)
    values (v_uid, v_total, 'mine', 'Industrial mines · ' || v_total || ' points');
  end if;
  return v_total;
end;
$$;

create or replace function public.my_mines()
returns table ("row" integer, col integer, mines integer, per_day integer, next_price integer, last_collected_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select s."row", s.col, s.mines, s.mines * public.mine_rate(),
         case when s.mines < public.max_mines() then public.mine_price(s.mines) end,
         s.last_collected_at
  from public.squares s
  where s.owner = auth.uid() and s.kind = 'industrial'
  order by s.claimed_at, s."row", s.col
$$;

-- ============================================================ $POINTS stats
-- supply      every point ever created = in_wallets + bank
-- in_wallets  points members hold right now
-- bank        points held by the central bank
-- mined       points paid out by mines, all time

drop function if exists public.points_stats();
create function public.points_stats()
returns table (supply bigint, in_wallets bigint, bank bigint, minted bigint, mined bigint, spent bigint, holders bigint,
               minted_24h bigint, net_24h bigint, mines bigint, daily_mine_output bigint, squares_claimed bigint,
               land_price integer, series jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with w as (select coalesce(sum(amount), 0)::bigint as v from public.ledger),
       b as (select coalesce(sum(amount), 0)::bigint as v from public.bank_ledger)
  select
    (select v from w) + (select v from b),
    (select v from w),
    (select v from b),
    coalesce((select sum(amount) from public.ledger where amount > 0), 0)::bigint,
    coalesce((select sum(amount) from public.ledger where kind = 'mine'), 0)::bigint,
    (select v from b),
    (select count(*) from public.profiles),
    coalesce((select sum(amount) from public.ledger where amount > 0 and created_at > now() - interval '24 hours'), 0)::bigint,
    coalesce((select sum(amount) from public.ledger where created_at > now() - interval '24 hours'), 0)::bigint,
    (select count(*) from public.squares where kind = 'industrial'),
    coalesce((select sum(s.mines) from public.squares s where s.kind = 'industrial'), 0)::bigint * public.mine_rate(),
    (select count(*) from public.squares),
    public.land_price(),
    -- At the end of each of the last 30 days (UTC): total supply, wallets and bank.
    (select jsonb_agg(jsonb_build_object(
        'day', d::date,
        'supply', x.wallets + x.bank,
        'wallets', x.wallets,
        'bank', x.bank) order by d)
     from generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day') d,
     lateral (select
        coalesce((select sum(amount) from public.ledger where created_at < d + interval '1 day'), 0) as wallets,
        coalesce((select sum(amount) from public.bank_ledger where created_at < d + interval '1 day'), 0) as bank) x)
$$;

-- ============================================================ access

revoke all on function public.bank_receive() from public, anon, authenticated;
grant execute on function public.points_stats() to anon, authenticated;
grant execute on function public.mine_rate() to anon, authenticated;
revoke all on function public.my_mines() from public, anon;
grant execute on function public.my_mines() to authenticated;
