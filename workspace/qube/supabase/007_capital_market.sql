-- QÜBE: the Capital, mine upgrades and ecosystem metrics.
-- Run once, after 006. SQL Editor → New query → paste → Run.
--
-- The Capital is three civic Squares in a row on the Sfere, which no member can own:
--   SQ 3·352·303  Penta   central government: the ecosystem's numbers (/penta)
--   SQ 3·353·303  Capital    the heart of the Sfere
--   SQ 3·354·303  Hexa    central bank: the market (/hexa)
-- Industrial Squares can hold up to 9 mines. Each mine pays 1 point a day.

-- ============================================================ the Capital

create table if not exists public.sfere_civic (
  key   text primary key,
  "row" integer not null,
  col   integer not null,
  name  text not null,
  unique ("row", col)
);
alter table public.sfere_civic enable row level security;
drop policy if exists "civic squares are public" on public.sfere_civic;
create policy "civic squares are public" on public.sfere_civic for select using (true);

insert into public.sfere_civic (key, "row", col, name) values
  ('pentagon', 1449, 352, 'Penta'),
  ('capital',  1449, 353, 'QÜBE Capital'),
  ('hexagon',  1449, 354, 'Hexa')
on conflict (key) do update set "row" = excluded."row", col = excluded.col, name = excluded.name;

-- Squares go on open land only: not water, not the Capital.
create or replace function public.squares_on_land()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.sfere_is_land(new."row", new.col) then
    raise exception 'That Square is ocean. Squares are only on land.' using errcode = '22023';
  end if;
  if exists (select 1 from public.sfere_civic c where c."row" = new."row" and c.col = new.col) then
    raise exception 'That Square belongs to the Capital.' using errcode = '22023';
  end if;
  return new;
end;
$$;

-- The nearest open land Square: same face, ring by ring, then anywhere in grid order.
create or replace function public.sfere_nearest_open(p_row integer, p_col integer, out r integer, out c integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_face integer := p_row / 573;
  v_y integer := p_row % 573;
  k integer := 1;
begin
  while r is null and k <= 40 loop
    select v_face * 573 + y, x into r, c
    from generate_series(greatest(0, v_y - k), least(572, v_y + k)) y,
         generate_series(greatest(0, p_col - k), least(572, p_col + k)) x
    where greatest(abs(y - v_y), abs(x - p_col)) = k
      and public.sfere_is_land(v_face * 573 + y, x)
      and not exists (select 1 from public.squares o where o."row" = v_face * 573 + y and o.col = x)
      and not exists (select 1 from public.sfere_civic o where o."row" = v_face * 573 + y and o.col = x)
    order by (y - v_y) ^ 2 + (x - p_col) ^ 2
    limit 1;
    k := k + 1;
  end loop;
  if r is null then
    select i / 573, i % 573 into r, c
    from public.sfere_land l, generate_series(l.start, l.stop - 1) i
    where not exists (select 1 from public.squares o where o."row" = i / 573 and o.col = i % 573)
      and not exists (select 1 from public.sfere_civic o where o."row" = i / 573 and o.col = i % 573)
    order by abs(i - (p_row * 573 + p_col))
    limit 1;
  end if;
end;
$$;

-- Anyone already on a Capital Square moves next door.
do $$
declare
  s record;
  v record;
begin
  for s in select q."row", q.col from public.squares q join public.sfere_civic c on c."row" = q."row" and c.col = q.col loop
    select * into v from public.sfere_nearest_open(s."row", s.col);
    update public.squares set "row" = v.r, col = v.c where "row" = s."row" and col = s.col;
  end loop;
end $$;

-- ============================================================ mines
-- Every Industrial Square starts with 1 mine. More can be bought at the Hexa,
-- up to 9. The next mine costs 50 points × the mines it already has.

alter table public.squares add column if not exists mines integer not null default 1;
alter table public.squares drop constraint if exists squares_mines_range;
alter table public.squares add constraint squares_mines_range check (mines between 1 and 9);

create or replace function public.max_mines() returns integer language sql immutable as $$ select 9 $$;
create or replace function public.mine_price(p_mines integer) returns integer language sql immutable as $$ select 50 * p_mines $$;

-- Pays every full day since the last payout, at each Square's mine count.
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
    v_total := v_total + v_days * s.mines;
  end loop;
  if v_total > 0 then
    insert into public.ledger (user_id, amount, kind, note)
    values (v_uid, v_total, 'mine', 'Industrial mines · ' || v_total || ' point' || case when v_total = 1 then '' else 's' end);
  end if;
  return v_total;
end;
$$;

create or replace function public.upgrade_mine(p_row integer, p_col integer)
returns public.squares
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_sq public.squares;
  v_price integer;
  v_balance bigint;
begin
  if v_uid is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  -- Pay out what the current mines have earned before adding one.
  perform public.collect_mines();
  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));
  select * into v_sq from public.squares where "row" = p_row and col = p_col for update;
  if v_sq is null or v_sq.owner <> v_uid then
    raise exception 'That Square isn''t yours' using errcode = '42501';
  end if;
  if v_sq.kind is distinct from 'industrial' then
    raise exception 'Mines go on Industrial Squares' using errcode = '22023';
  end if;
  if v_sq.mines >= public.max_mines() then
    raise exception 'That Square already has % mines, the most it can hold', public.max_mines() using errcode = 'P0001';
  end if;
  v_price := public.mine_price(v_sq.mines);
  select coalesce(sum(amount), 0) into v_balance from public.ledger where user_id = v_uid;
  if v_balance < v_price then
    raise exception 'The next mine costs % points. You have %.', v_price, v_balance using errcode = 'P0001';
  end if;
  insert into public.ledger (user_id, amount, kind, note)
  values (v_uid, -v_price, 'spend', 'Mine ' || (v_sq.mines + 1) || ' on an Industrial Square');
  update public.squares set mines = mines + 1 where "row" = p_row and col = p_col returning * into v_sq;
  return v_sq;
end;
$$;

create or replace function public.my_mines()
returns table ("row" integer, col integer, mines integer, per_day integer, next_price integer, last_collected_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select s."row", s.col, s.mines, s.mines,
         case when s.mines < public.max_mines() then public.mine_price(s.mines) end,
         s.last_collected_at
  from public.squares s
  where s.owner = auth.uid() and s.kind = 'industrial'
  order by s.claimed_at, s."row", s.col
$$;

-- The Sfere's Squares, now with each one's mine count.
drop function if exists public.sfere_squares();
create function public.sfere_squares()
returns table ("row" integer, col integer, handle text, color text, kind text, posts integer, claimed_at timestamptz, agent_name text, mines integer)
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
         s.mines
  from public.squares s
  join public.profiles p on p.id = s.owner
  left join social so on so."row" = s."row" and so.col = s.col
  left join counts c on c.author = s.owner
  left join public.agents ag on ag.home_row = s."row" and ag.home_col = s.col
$$;

-- Daily mine output is now the sum of all mines.
create or replace function public.points_stats()
returns table (supply bigint, minted bigint, spent bigint, holders bigint, minted_24h bigint, net_24h bigint,
               mines bigint, daily_mine_output bigint, squares_claimed bigint, land_price integer, series jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((select sum(amount) from public.ledger), 0)::bigint,
    coalesce((select sum(amount) from public.ledger where amount > 0), 0)::bigint,
    coalesce((select -sum(amount) from public.ledger where kind = 'spend'), 0)::bigint,
    (select count(*) from public.profiles),
    coalesce((select sum(amount) from public.ledger where amount > 0 and created_at > now() - interval '24 hours'), 0)::bigint,
    coalesce((select sum(amount) from public.ledger where created_at > now() - interval '24 hours'), 0)::bigint,
    (select count(*) from public.squares where kind = 'industrial'),
    coalesce((select sum(s.mines) from public.squares s where s.kind = 'industrial'), 0)::bigint,
    (select count(*) from public.squares),
    public.land_price(),
    (select jsonb_agg(jsonb_build_object('day', d::date, 'supply', coalesce((
        select sum(amount) from public.ledger where created_at < d + interval '1 day'), 0)) order by d)
     from generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day') d)
$$;

-- ============================================================ site visits
-- One row per visitor, page and day. The visitor id is a random id the browser keeps;
-- nothing about the person is stored.

create table if not exists public.site_visits (
  day      date not null default (now() at time zone 'utc')::date,
  visitor  text not null check (visitor ~ '^[a-z0-9-]{8,40}$'),
  path     text not null check (path ~ '^/[a-z0-9/_-]{0,40}$'),
  hits     integer not null default 1,
  primary key (day, visitor, path)
);
alter table public.site_visits enable row level security;
-- No policies: only log_visit() writes and ecosystem_stats() reads.

create or replace function public.log_visit(p_path text, p_visitor text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.site_visits (visitor, path) values (p_visitor, p_path)
  on conflict (day, visitor, path) do update set hits = least(public.site_visits.hits + 1, 500)
$$;

-- ============================================================ the Penta's numbers

create or replace function public.ecosystem_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with days as (
    select d::date as day
    from generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day') d
  )
  select jsonb_build_object(
    'members',            (select count(*) from public.profiles),
    'members_complete',   (select count(*) from public.profiles where color is not null),
    'members_24h',        (select count(*) from public.profiles where created_at > now() - interval '24 hours'),
    'members_7d',         (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'invites_used',       (select count(*) from public.invites where used_by is not null),
    'invites_open',       (select count(*) from public.invites where used_by is null),
    'visits_24h',         coalesce((select sum(hits) from public.site_visits where day >= (now() at time zone 'utc')::date - 1), 0),
    'visitors_24h',       (select count(distinct visitor) from public.site_visits where day >= (now() at time zone 'utc')::date - 1),
    'visitors_7d',        (select count(distinct visitor) from public.site_visits where day >= (now() at time zone 'utc')::date - 6),
    'posts',              (select count(*) from public.posts where parent_id is null),
    'replies',            (select count(*) from public.posts where parent_id is not null),
    'posts_24h',          (select count(*) from public.posts where created_at > now() - interval '24 hours'),
    'likes',              (select count(*) from public.likes),
    'likes_24h',          (select count(*) from public.likes where created_at > now() - interval '24 hours'),
    'agents',             (select count(*) from public.agents),
    'agent_messages',     (select count(*) from public.agent_messages),
    'agent_messages_24h', (select count(*) from public.agent_messages where created_at > now() - interval '24 hours'),
    'land_total',         (select coalesce(sum(stop - start), 0) from public.sfere_land),
    'squares',            (select count(*) from public.squares),
    'residential',        (select count(*) from public.squares where kind = 'residential'),
    'industrial',         (select count(*) from public.squares where kind = 'industrial'),
    'social',             (select count(*) from public.squares where kind = 'social'),
    'mines',              coalesce((select sum(mines) from public.squares where kind = 'industrial'), 0),
    'squares_bought',     (select count(*) from public.square_grants where reason = 'purchase'),
    'landowners',         (select count(distinct owner) from public.squares),
    'top_landowners',     coalesce((
        select jsonb_agg(t order by t.squares desc, t.handle)
        from (select p.handle, p.color, count(*) as squares
              from public.squares s join public.profiles p on p.id = s.owner
              group by p.handle, p.color order by count(*) desc, p.handle limit 5) t), '[]'::jsonb),
    'series', (select jsonb_agg(jsonb_build_object(
        'day', d.day,
        'members', (select count(*) from public.profiles where (created_at at time zone 'utc')::date = d.day),
        'posts',   (select count(*) from public.posts where (created_at at time zone 'utc')::date = d.day),
        'visits',  coalesce((select sum(hits) from public.site_visits v where v.day = d.day), 0),
        'visitors', (select count(distinct visitor) from public.site_visits v where v.day = d.day),
        'squares', (select count(*) from public.squares where (claimed_at at time zone 'utc')::date = d.day)
      ) order by d.day) from days d)
  )
$$;

-- ============================================================ access

revoke all on function public.sfere_nearest_open(integer, integer) from public, anon, authenticated;
revoke all on function public.upgrade_mine(integer, integer) from public, anon;
revoke all on function public.my_mines() from public, anon;
grant execute on function public.upgrade_mine(integer, integer) to authenticated;
grant execute on function public.my_mines() to authenticated;
grant execute on function public.sfere_squares() to anon, authenticated;
grant execute on function public.log_visit(text, text) to anon, authenticated;
grant execute on function public.ecosystem_stats() to anon, authenticated;
grant execute on function public.max_mines() to anon, authenticated;
grant execute on function public.mine_price(integer) to anon, authenticated;
