-- QÜBE: Agricultural and Promotional Squares, tokenberries, hungry agents,
-- the secondary market, and a bigger Capital.
-- Run once, after 008. SQL Editor → New query → paste → Run.
--
-- Agricultural  a Tokenberry field: harvest 9 tokenberries a day by clicking it on the Sfere.
-- Promotional   shows one image, chosen by its owner, on the Sfere.
-- Move residence  placing a new Square can make it the agent's home; the old home
--                 goes back to "no type yet" so its owner can choose again.
-- Agents get hungry. Chatting and time use up fullness; tokenberries refill it.
-- At 0 the agent won't talk until it's fed.
-- The Hexa gains a secondary market: members list Squares and tokenberries at any price.

-- ============================================================ Square types

alter table public.squares drop constraint if exists squares_kind_check;
alter table public.squares add constraint squares_kind_check
  check (kind in ('residential', 'industrial', 'social', 'agricultural', 'promotional'));

alter table public.squares
  add column if not exists last_harvest_on date,
  add column if not exists promo_url text;

create or replace function public.square_kinds() returns text[] language sql immutable as $$
  select array['residential', 'industrial', 'social', 'agricultural', 'promotional']
$$;

-- p_kind may also be 'move_home': a Residential Square that becomes the agent's new home.
create or replace function public.claim_square(p_row integer, p_col integer, p_kind text)
returns public.squares
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_available integer;
  v_sq public.squares;
  v_agent public.agents;
  v_kind text := p_kind;
begin
  if not exists (select 1 from public.profiles where id = v_uid and color is not null) then
    raise exception 'Finish your profile first' using errcode = 'P0002';
  end if;
  if p_kind = 'move_home' then
    select * into v_agent from public.agents where owner = v_uid;
    if v_agent.id is null then
      raise exception 'You don''t have an agent to move yet' using errcode = 'P0001';
    end if;
    v_kind := 'residential';
  elsif p_kind is null or not (p_kind = any (public.square_kinds())) then
    raise exception 'Choose a type for this Square' using errcode = '22023';
  end if;
  if p_row < 0 or p_row >= public.sfere_rows() or p_col < 0 or p_col >= public.sfere_cols(p_row) then
    raise exception 'That Square is off the grid' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  select (select count(*) from public.square_grants where user_id = v_uid)
       - (select count(*) from public.squares where owner = v_uid)
  into v_available;
  if v_available <= 0 then
    raise exception 'You have no Squares left to place. Buy one at the Hexa or invite someone.' using errcode = 'P0001';
  end if;

  begin
    insert into public.squares ("row", col, owner, kind, last_collected_at)
    values (p_row, p_col, v_uid, v_kind, now())
    returning * into v_sq;
  exception when unique_violation then
    raise exception 'Someone already owns that Square' using errcode = '23505';
  end;

  if p_kind = 'move_home' then
    -- The agent moves in; its old home waits for a new type.
    update public.agents set home_row = p_row, home_col = p_col where id = v_agent.id;
    update public.squares set kind = null
    where "row" = v_agent.home_row and col = v_agent.home_col and owner = v_uid;
  end if;
  return v_sq;
end;
$$;

create or replace function public.set_square_kind(p_row integer, p_col integer, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind is null or not (p_kind = any (public.square_kinds())) then
    raise exception 'Choose a type for this Square' using errcode = '22023';
  end if;
  update public.squares set kind = p_kind, last_collected_at = now(), mines = 1, promo_url = null, last_harvest_on = null
  where "row" = p_row and col = p_col and owner = auth.uid() and kind is null;
  if not found then
    raise exception 'That Square already has a type, or isn''t yours' using errcode = 'P0001';
  end if;
end;
$$;

-- Promotional Squares show one image, uploaded by their owner to their own folder.
create or replace function public.set_square_image(p_row integer, p_col integer, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if p_url is not null and position('/storage/v1/object/public/line-media/' || v_uid::text || '/' in p_url) = 0 then
    raise exception 'Upload the image from QÜBE first' using errcode = '22023';
  end if;
  update public.squares set promo_url = p_url
  where "row" = p_row and col = p_col and owner = v_uid and kind = 'promotional';
  if not found then
    raise exception 'Only your Promotional Squares can show an image' using errcode = 'P0001';
  end if;
end;
$$;

-- ============================================================ tokenberries

create table if not exists public.berry_ledger (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  amount      integer not null,
  kind        text not null check (kind in ('harvest', 'gift', 'feed', 'escrow', 'release', 'buy')),
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists berry_ledger_user_idx on public.berry_ledger (user_id, created_at desc);
alter table public.berry_ledger enable row level security;
drop policy if exists "read own berries" on public.berry_ledger;
create policy "read own berries" on public.berry_ledger for select using (user_id = auth.uid());

create or replace function public.berries_of(p_uid uuid) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::integer from public.berry_ledger where user_id = p_uid
$$;

create or replace function public.my_berries() returns integer
language sql stable security definer set search_path = public as $$
  select public.berries_of(auth.uid())
$$;

create or replace function public.berries_per_harvest() returns integer language sql immutable as $$ select 9 $$;

-- Once per UTC day, per Agricultural Square, from the Sfere.
create or replace function public.harvest_square(p_row integer, p_col integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
begin
  update public.squares set last_harvest_on = v_today
  where "row" = p_row and col = p_col and owner = v_uid and kind = 'agricultural'
    and (last_harvest_on is null or last_harvest_on < v_today);
  if not found then
    if exists (select 1 from public.squares where "row" = p_row and col = p_col and owner = v_uid and kind = 'agricultural') then
      raise exception 'Already harvested today. The Tokenberries ripen again at midnight UTC.' using errcode = 'P0001';
    end if;
    raise exception 'Only your Agricultural Squares can be harvested' using errcode = 'P0001';
  end if;
  insert into public.berry_ledger (user_id, amount, kind, note)
  values (v_uid, public.berries_per_harvest(), 'harvest', 'Harvested a Tokenberry field');
  return public.berries_of(v_uid);
end;
$$;

-- ============================================================ hungry agents
-- fullness 0–100. It drops 2 an hour and 4 per message; each tokenberry adds 10.

alter table public.agents
  add column if not exists fullness numeric not null default 100,
  add column if not exists fullness_at timestamptz not null default now();

create or replace function public.agent_fullness(p_fullness numeric, p_at timestamptz) returns integer
language sql stable as $$
  select greatest(0, least(100, floor(p_fullness - 2 * extract(epoch from (now() - p_at)) / 3600)))::integer
$$;

create or replace function public.agent_status()
returns table (fullness integer, berries integer, per_berry integer, per_message integer, per_hour integer)
language sql
stable
security definer
set search_path = public
as $$
  select public.agent_fullness(a.fullness, a.fullness_at), public.berries_of(auth.uid()), 10, 4, 2
  from public.agents a where a.owner = auth.uid()
$$;

-- Feeds up to p_berries, never more than it takes to fill the agent.
create or replace function public.feed_agent(p_berries integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_agent public.agents;
  v_now integer;
  v_use integer;
begin
  perform pg_advisory_xact_lock(hashtext('berries:' || v_uid::text));
  select * into v_agent from public.agents where owner = v_uid for update;
  if v_agent.id is null then raise exception 'You don''t have an agent yet' using errcode = 'P0001'; end if;
  v_now := public.agent_fullness(v_agent.fullness, v_agent.fullness_at);
  v_use := least(coalesce(p_berries, 0), ceil((100 - v_now) / 10.0)::integer);
  if v_use <= 0 then return v_now; end if;
  if public.berries_of(v_uid) < v_use then
    raise exception 'You need % tokenberries. Harvest an Agricultural Square or buy some at the Hexa.', v_use using errcode = 'P0001';
  end if;
  insert into public.berry_ledger (user_id, amount, kind, note) values (v_uid, -v_use, 'feed', 'Fed ' || v_agent.name);
  update public.agents set fullness = least(100, v_now + 10 * v_use), fullness_at = now() where id = v_agent.id;
  return least(100, v_now + 10 * v_use);
end;
$$;

-- Called by the agent-chat function (service role) for each message. Raises when hungry.
create or replace function public.agent_eat(p_agent uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent public.agents;
  v_now integer;
begin
  select * into v_agent from public.agents where id = p_agent for update;
  v_now := public.agent_fullness(v_agent.fullness, v_agent.fullness_at);
  if v_now <= 0 then
    raise exception 'hungry' using errcode = 'P0001';
  end if;
  update public.agents set fullness = greatest(0, v_now - 4), fullness_at = now() where id = p_agent;
  return greatest(0, v_now - 4);
end;
$$;

-- Every new agent arrives full, with a first harvest's worth of tokenberries.
create or replace function public.agent_welcome_berries()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.berry_ledger (user_id, amount, kind, note)
  values (new.owner, public.berries_per_harvest(), 'gift', 'A welcome basket for ' || new.name);
  return new;
end;
$$;
drop trigger if exists agents_welcome_berries on public.agents;
create trigger agents_welcome_berries after insert on public.agents
  for each row execute function public.agent_welcome_berries();

-- Agents that already exist get the same basket.
insert into public.berry_ledger (user_id, amount, kind, note)
select a.owner, public.berries_per_harvest(), 'gift', 'A welcome basket for ' || a.name
from public.agents a
where not exists (select 1 from public.berry_ledger b where b.user_id = a.owner and b.kind = 'gift');

-- ============================================================ the secondary market
-- Members list a placed Square or tokenberries at a price they choose. Points go
-- straight from buyer to seller. Listed tokenberries are held until sold or cancelled.

alter table public.square_grants drop constraint if exists square_grants_reason_check;
alter table public.square_grants add constraint square_grants_reason_check
  check (reason in ('signup', 'referral', 'admin', 'purchase', 'trade'));

create table if not exists public.market_listings (
  id          bigint generated always as identity primary key,
  seller      uuid not null references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('square', 'berries')),
  "row"       integer,
  col         integer,
  quantity    integer not null default 1 check (quantity >= 0),
  unit_price  bigint not null check (unit_price between 1 and 1000000000),
  status      text not null default 'open' check (status in ('open', 'sold', 'cancelled')),
  created_at  timestamptz not null default now(),
  closed_at   timestamptz,
  check ((kind = 'square') = ("row" is not null and col is not null))
);
create unique index if not exists market_one_listing_per_square on public.market_listings ("row", col) where status = 'open';
create index if not exists market_open_idx on public.market_listings (kind, created_at desc) where status = 'open';
alter table public.market_listings enable row level security;
drop policy if exists "listings are public" on public.market_listings;
create policy "listings are public" on public.market_listings for select using (true);

create table if not exists public.market_trades (
  id          bigint generated always as identity primary key,
  listing_id  bigint references public.market_listings (id) on delete set null,
  kind        text not null,
  seller      uuid references public.profiles (id) on delete set null,
  buyer       uuid references public.profiles (id) on delete set null,
  "row"       integer,
  col         integer,
  quantity    integer not null,
  unit_price  bigint not null,
  total       bigint not null,
  created_at  timestamptz not null default now()
);
create index if not exists market_trades_idx on public.market_trades (kind, created_at desc);
alter table public.market_trades enable row level security;
drop policy if exists "trades are public" on public.market_trades;
create policy "trades are public" on public.market_trades for select using (true);

create or replace function public.list_square(p_row integer, p_col integer, p_price bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id bigint;
begin
  if not exists (select 1 from public.squares where "row" = p_row and col = p_col and owner = v_uid) then
    raise exception 'That Square isn''t yours' using errcode = '42501';
  end if;
  if exists (select 1 from public.agents where home_row = p_row and home_col = p_col) then
    raise exception 'Your agent lives there. Move its residence before selling this Square.' using errcode = 'P0001';
  end if;
  if p_price is null or p_price < 1 then
    raise exception 'Set a price of at least 1 point' using errcode = '22023';
  end if;
  begin
    insert into public.market_listings (seller, kind, "row", col, quantity, unit_price)
    values (v_uid, 'square', p_row, p_col, 1, p_price) returning id into v_id;
  exception when unique_violation then
    raise exception 'That Square is already listed' using errcode = '23505';
  end;
  return v_id;
end;
$$;

create or replace function public.list_berries(p_quantity integer, p_unit_price bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id bigint;
begin
  if p_quantity is null or p_quantity < 1 then raise exception 'List at least 1 tokenberry' using errcode = '22023'; end if;
  if p_unit_price is null or p_unit_price < 1 then raise exception 'Set a price of at least 1 point' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('berries:' || v_uid::text));
  if public.berries_of(v_uid) < p_quantity then
    raise exception 'You have % tokenberries', public.berries_of(v_uid) using errcode = 'P0001';
  end if;
  insert into public.market_listings (seller, kind, quantity, unit_price)
  values (v_uid, 'berries', p_quantity, p_unit_price) returning id into v_id;
  insert into public.berry_ledger (user_id, amount, kind, note)
  values (v_uid, -p_quantity, 'escrow', 'Listed on the market (#' || v_id || ')');
  return v_id;
end;
$$;

create or replace function public.cancel_listing(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_l public.market_listings;
begin
  select * into v_l from public.market_listings where id = p_id for update;
  if v_l.id is null or v_l.seller <> auth.uid() then raise exception 'That listing isn''t yours' using errcode = '42501'; end if;
  if v_l.status <> 'open' then raise exception 'That listing is already closed' using errcode = 'P0001'; end if;
  update public.market_listings set status = 'cancelled', closed_at = now() where id = p_id;
  if v_l.kind = 'berries' and v_l.quantity > 0 then
    insert into public.berry_ledger (user_id, amount, kind, note)
    values (v_l.seller, v_l.quantity, 'release', 'Listing #' || p_id || ' cancelled');
  end if;
end;
$$;

-- Buy a listed Square, or p_quantity tokenberries from a listing (all of them when null).
create or replace function public.buy_listing(p_id bigint, p_quantity integer default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_l public.market_listings;
  v_sq public.squares;
  v_qty integer;
  v_total bigint;
  v_balance bigint;
  v_owed integer;
  v_grant bigint;
  v_label text;
begin
  if not exists (select 1 from public.profiles where id = v_uid and color is not null) then
    raise exception 'Finish your profile first' using errcode = 'P0002';
  end if;
  select * into v_l from public.market_listings where id = p_id for update;
  if v_l.id is null or v_l.status <> 'open' then raise exception 'That listing is no longer for sale' using errcode = 'P0001'; end if;
  if v_l.seller = v_uid then raise exception 'That''s your own listing' using errcode = 'P0001'; end if;

  v_qty := case when v_l.kind = 'square' then 1 else least(coalesce(p_quantity, v_l.quantity), v_l.quantity) end;
  if v_qty < 1 then raise exception 'Buy at least 1' using errcode = '22023'; end if;
  v_total := v_qty * v_l.unit_price;

  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));
  select coalesce(sum(amount), 0) into v_balance from public.ledger where user_id = v_uid;
  if v_balance < v_total then
    raise exception 'That costs % points. You have %.', v_total, v_balance using errcode = 'P0001';
  end if;

  if v_l.kind = 'square' then
    select * into v_sq from public.squares where "row" = v_l."row" and col = v_l.col for update;
    if v_sq."row" is null or v_sq.owner <> v_l.seller then
      update public.market_listings set status = 'cancelled', closed_at = now() where id = p_id;
      raise exception 'That Square has changed hands' using errcode = 'P0001';
    end if;
    -- The seller keeps what the mines earned up to now.
    if v_sq.kind = 'industrial' then
      v_owed := floor(extract(epoch from (now() - v_sq.last_collected_at)) / 86400)::integer * v_sq.mines * public.mine_rate();
      if v_owed > 0 then
        insert into public.ledger (user_id, amount, kind, note) values (v_l.seller, v_owed, 'mine', 'Industrial mines · ' || v_owed || ' points');
      end if;
    end if;
    update public.squares set owner = v_uid, promo_url = null, last_collected_at = now(), claimed_at = now()
    where "row" = v_sq."row" and col = v_sq.col;
    -- A Square's placement right moves with it: one of the seller's grants becomes the buyer's.
    select id into v_grant from public.square_grants where user_id = v_l.seller
    order by (reason = 'referral'), created_at desc limit 1;
    update public.square_grants
    set user_id = v_uid,
        reason = case when reason = 'referral' then 'trade' else reason end,
        source_user = case when reason = 'referral' then null else source_user end
    where id = v_grant;
    v_label := 'Square ' || v_sq."row" || '.' || v_sq.col;
    update public.market_listings set status = 'sold', quantity = 0, closed_at = now() where id = p_id;
  else
    insert into public.berry_ledger (user_id, amount, kind, note) values (v_uid, v_qty, 'buy', 'Bought on the market (#' || p_id || ')');
    v_label := v_qty || ' tokenberr' || case when v_qty = 1 then 'y' else 'ies' end;
    update public.market_listings
    set quantity = quantity - v_qty,
        status = case when quantity - v_qty = 0 then 'sold' else 'open' end,
        closed_at = case when quantity - v_qty = 0 then now() end
    where id = p_id;
  end if;

  insert into public.ledger (user_id, amount, kind, note) values (v_uid, -v_total, 'transfer_out', 'Bought ' || v_label);
  insert into public.ledger (user_id, amount, kind, note) values (v_l.seller, v_total, 'transfer_in', 'Sold ' || v_label);
  insert into public.market_trades (listing_id, kind, seller, buyer, "row", col, quantity, unit_price, total)
  values (p_id, v_l.kind, v_l.seller, v_uid, v_l."row", v_l.col, v_qty, v_l.unit_price, v_total);
  return v_total;
end;
$$;

create or replace function public.market_open()
returns table (id bigint, kind text, seller_handle text, seller_color text, "row" integer, col integer,
               square_kind text, mines integer, quantity integer, unit_price bigint, created_at timestamptz, mine boolean)
language sql
stable
security definer
set search_path = public
as $$
  select l.id, l.kind, p.handle, p.color, l."row", l.col, s.kind, s.mines, l.quantity, l.unit_price, l.created_at,
         l.seller = auth.uid()
  from public.market_listings l
  join public.profiles p on p.id = l.seller
  left join public.squares s on s."row" = l."row" and s.col = l.col
  where l.status = 'open'
  order by l.kind, l.unit_price, l.created_at
$$;

create or replace function public.market_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'berry_last',     (select unit_price from public.market_trades where kind = 'berries' order by created_at desc limit 1),
    'berry_avg_7d',   (select round(sum(total)::numeric / nullif(sum(quantity), 0), 1) from public.market_trades where kind = 'berries' and created_at > now() - interval '7 days'),
    'berry_volume_24h', coalesce((select sum(quantity) from public.market_trades where kind = 'berries' and created_at > now() - interval '24 hours'), 0),
    'berry_ask',      (select min(unit_price) from public.market_listings where kind = 'berries' and status = 'open'),
    'land_last',      (select unit_price from public.market_trades where kind = 'square' order by created_at desc limit 1),
    'land_avg_30d',   (select round(avg(unit_price)) from public.market_trades where kind = 'square' and created_at > now() - interval '30 days'),
    'land_ask',       (select min(unit_price) from public.market_listings where kind = 'square' and status = 'open'),
    'trades_24h',     (select count(*) from public.market_trades where created_at > now() - interval '24 hours'),
    'open_listings',  (select count(*) from public.market_listings where status = 'open')
  )
$$;

-- ============================================================ the Sfere's Squares

drop function if exists public.sfere_squares();
create function public.sfere_squares()
returns table ("row" integer, col integer, handle text, color text, kind text, posts integer, claimed_at timestamptz,
               agent_name text, mines integer, promo_url text, ripe boolean, price bigint, listing_id bigint)
language sql
stable
security definer
set search_path = public
as $$
  with social as (
    select s."row", s.col, s.owner,
           row_number() over (partition by s.owner order by s.claimed_at, s."row", s.col) - 1 as idx
    from public.squares s where s.kind = 'social'
  ),
  counts as (
    select author, count(*) as n from public.posts where parent_id is null group by author
  )
  select s."row", s.col, p.handle, p.color, s.kind,
         case when s.kind = 'social'
              then least(9, greatest(0, coalesce(c.n, 0) - 9 * so.idx))::integer
              else 0 end,
         s.claimed_at,
         ag.name,
         s.mines,
         s.promo_url,
         s.kind = 'agricultural' and (s.last_harvest_on is null or s.last_harvest_on < (now() at time zone 'utc')::date),
         ml.unit_price,
         ml.id
  from public.squares s
  join public.profiles p on p.id = s.owner
  left join social so on so."row" = s."row" and so.col = s.col
  left join counts c on c.author = s.owner
  left join public.agents ag on ag.home_row = s."row" and ag.home_col = s.col
  left join public.market_listings ml on ml."row" = s."row" and ml.col = s.col and ml.status = 'open'
$$;

-- ============================================================ the Capital, 3 × 3
--   Central Bank · Central Intelligence (Penta) · The Līnē
--   Plaza        · QÜBE Capital                 · Plaza
--   Customs      · Central Market (Hexa)         · Arcade

insert into public.sfere_civic (key, "row", col, name) values
  ('pentagon', 1449, 352, 'Central Intelligence'),
  ('capital',  1449, 353, 'QÜBE Capital'),
  ('hexagon',  1449, 354, 'Central Market'),
  ('bank',     1448, 352, 'Central Bank'),
  ('line',     1450, 352, 'The Līnē'),
  ('plaza_w',  1448, 353, 'Capital Plaza'),
  ('plaza_e',  1450, 353, 'Capital Plaza'),
  ('customs',  1448, 354, 'Customs'),
  ('arcade',   1450, 354, 'Arcade')
on conflict (key) do update set "row" = excluded."row", col = excluded.col, name = excluded.name;

-- Anyone already on the new Capital Squares moves next door.
do $$
declare
  s record;
  v record;
begin
  for s in select q."row", q.col from public.squares q join public.sfere_civic c on c."row" = q."row" and c.col = q.col loop
    select * into v from public.sfere_nearest_open(s."row", s.col);
    update public.market_listings set status = 'cancelled', closed_at = now() where "row" = s."row" and col = s.col and status = 'open';
    update public.squares set "row" = v.r, col = v.c where "row" = s."row" and col = s.col;
  end loop;
end $$;

-- ============================================================ access

revoke all on function public.claim_square(integer, integer, text) from public, anon;
revoke all on function public.set_square_kind(integer, integer, text) from public, anon;
revoke all on function public.set_square_image(integer, integer, text) from public, anon;
revoke all on function public.harvest_square(integer, integer) from public, anon;
revoke all on function public.my_berries() from public, anon;
revoke all on function public.berries_of(uuid) from public, anon, authenticated;
revoke all on function public.agent_status() from public, anon;
revoke all on function public.feed_agent(integer) from public, anon;
revoke all on function public.agent_eat(uuid) from public, anon, authenticated;
revoke all on function public.agent_welcome_berries() from public, anon, authenticated;
revoke all on function public.list_square(integer, integer, bigint) from public, anon;
revoke all on function public.list_berries(integer, bigint) from public, anon;
revoke all on function public.cancel_listing(bigint) from public, anon;
revoke all on function public.buy_listing(bigint, integer) from public, anon;
grant execute on function public.claim_square(integer, integer, text) to authenticated;
grant execute on function public.set_square_kind(integer, integer, text) to authenticated;
grant execute on function public.set_square_image(integer, integer, text) to authenticated;
grant execute on function public.harvest_square(integer, integer) to authenticated;
grant execute on function public.my_berries() to authenticated;
grant execute on function public.agent_status() to authenticated;
grant execute on function public.feed_agent(integer) to authenticated;
grant execute on function public.list_square(integer, integer, bigint) to authenticated;
grant execute on function public.list_berries(integer, bigint) to authenticated;
grant execute on function public.cancel_listing(bigint) to authenticated;
grant execute on function public.buy_listing(bigint, integer) to authenticated;
grant execute on function public.market_open() to anon, authenticated;
grant execute on function public.market_stats() to anon, authenticated;
grant execute on function public.sfere_squares() to anon, authenticated;
grant execute on function public.square_kinds() to anon, authenticated;
