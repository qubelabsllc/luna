-- QÜBE 004: profile details, the cube-sphere grid, Square types, mines,
-- the land market, Social post slots, and $POINTS stats.
-- Run after 001–003 (or after setup.sql). Safe on a database that already has members and Squares.

-- ============================================================ profile details
-- Onboarding asks for a color (permanent), birthday and gender. Only the member
-- can read their birthday and gender; the color is public.

alter table public.profiles
  add column color     text,
  add column birthday  date,
  add column gender    text;

create or replace function public.qube_colors()
returns text[] language sql immutable as $$
  select array['#3a3df5','#e0584a','#f08a24','#e8b817','#7cb518','#12a150',
               '#0fa3a3','#2d9cdb','#7b4ae2','#d63384','#f06595','#3d3f46']
$$;

alter table public.profiles
  add constraint profile_color check (color is null or color = any (public.qube_colors())),
  add constraint profile_gender check (gender is null or gender in ('woman', 'man', 'nonbinary', 'other', 'unspecified')),
  add constraint profile_birthday check (birthday is null or birthday between date '1900-01-01' and current_date);

create or replace function public.complete_profile(p_color text, p_birthday date, p_gender text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_color text;
begin
  select color into v_color from public.profiles where id = v_uid for update;
  if not found then
    raise exception 'Pick a handle first' using errcode = 'P0002';
  end if;
  if v_color is not null then
    raise exception 'Your profile is already complete. Colors are permanent.' using errcode = 'P0001';
  end if;
  if not (p_color = any (public.qube_colors())) then
    raise exception 'Pick one of the QÜBE colors' using errcode = '22023';
  end if;
  if p_birthday is null or p_birthday > (current_date - interval '13 years')::date or p_birthday < date '1900-01-01' then
    raise exception 'You need to be 13 or older to join QÜBE' using errcode = '22023';
  end if;
  if p_gender is null or p_gender not in ('woman', 'man', 'nonbinary', 'other', 'unspecified') then
    raise exception 'Pick a gender option' using errcode = '22023';
  end if;
  update public.profiles set color = p_color, birthday = p_birthday, gender = p_gender where id = v_uid;
end;
$$;

-- ============================================================ cube-sphere grid
-- The Sfere is now a cube inflated into a sphere. Each of the 6 faces is cut
-- into 573 × 573 Squares (equiangular), so rows and columns run straight.
-- 6 × 573² = 1,969,974 Squares averaging 10 × 10 miles.
-- A Square is (row, col) with row = face * 573 + y and col = x.
-- The same math lives in qube.js; keep them in step.

create or replace function public.sfere_n() returns integer language sql immutable as $$ select 573 $$;

-- Which Square contains a latitude/longitude.
create or replace function public.sfere_cell(p_lat double precision, p_lon double precision, out "row" integer, out col integer)
language plpgsql immutable as $$
declare
  n constant integer := 573;
  la double precision := radians(p_lat);
  lo double precision := radians(p_lon);
  x double precision := cos(la) * cos(lo);
  y double precision := sin(la);
  z double precision := -cos(la) * sin(lo);
  ax double precision := abs(x); ay double precision := abs(y); az double precision := abs(z);
  face integer; a double precision; b double precision;
begin
  if ax >= ay and ax >= az then
    if x > 0 then face := 0; a := -z / ax; b := y / ax; else face := 1; a := z / ax; b := y / ax; end if;
  elsif ay >= az then
    if y > 0 then face := 2; a := x / ay; b := -z / ay; else face := 3; a := x / ay; b := z / ay; end if;
  else
    if z > 0 then face := 4; a := x / az; b := y / az; else face := 5; a := -x / az; b := y / az; end if;
  end if;
  col := least(n - 1, greatest(0, floor((atan(a) + pi() / 4) / (pi() / 2) * n)::integer));
  "row" := face * n + least(n - 1, greatest(0, floor((atan(b) + pi() / 4) / (pi() / 2) * n)::integer));
end;
$$;

-- Move existing Squares from the old latitude-band grid to the cube grid.
alter table public.squares drop constraint square_in_grid;

do $$
declare
  s record;
  c record;
begin
  for s in select "row", col from public.squares loop
    select * into c from public.sfere_cell(
      -90 + (s."row" + 0.5) * 180.0 / 1243,
      -180 + (s.col + 0.5) * 360.0 / public.sfere_cols(s."row")
    );
    -- Two old Squares could land on one new Square; the later one takes the next free column.
    while exists (select 1 from public.squares q where q."row" = c."row" and q.col = c.col
                  and not (q."row" = s."row" and q.col = s.col)) loop
      c.col := (c.col + 1) % 573;
    end loop;
    update public.squares set "row" = c."row", col = c.col where "row" = s."row" and col = s.col;
  end loop;
end $$;

create or replace function public.sfere_rows() returns integer language sql immutable as $$ select 6 * 573 $$;
create or replace function public.sfere_cols(p_row integer) returns integer language sql immutable as $$ select 573 $$;

alter table public.squares add constraint square_in_grid
  check ("row" >= 0 and "row" < 6 * 573 and col >= 0 and col < 573);

-- ============================================================ Square types
-- residential: where the member's agent will live (decorating comes later)
-- industrial:  a points mine, 1 point a day
-- social:      9 post slots on the Line

alter table public.squares
  add column kind text check (kind in ('residential', 'industrial', 'social')),
  add column last_collected_at timestamptz;

drop function if exists public.claim_square(integer, integer);

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
begin
  if not exists (select 1 from public.profiles where id = v_uid and color is not null) then
    raise exception 'Finish your profile first' using errcode = 'P0002';
  end if;
  if p_kind is null or p_kind not in ('residential', 'industrial', 'social') then
    raise exception 'Choose Residential, Industrial or Social' using errcode = '22023';
  end if;
  if p_row < 0 or p_row >= public.sfere_rows() or p_col < 0 or p_col >= public.sfere_cols(p_row) then
    raise exception 'That Square is off the grid' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  select (select count(*) from public.square_grants where user_id = v_uid)
       - (select count(*) from public.squares where owner = v_uid)
  into v_available;
  if v_available <= 0 then
    raise exception 'You have no Squares left to place. Buy one for 100 points or invite someone.' using errcode = 'P0001';
  end if;

  begin
    insert into public.squares ("row", col, owner, kind, last_collected_at)
    values (p_row, p_col, v_uid, p_kind, now())
    returning * into v_sq;
  exception when unique_violation then
    raise exception 'Someone already owns that Square' using errcode = '23505';
  end;
  return v_sq;
end;
$$;

-- Squares placed before types existed get their type chosen once.
create or replace function public.set_square_kind(p_row integer, p_col integer, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_kind is null or p_kind not in ('residential', 'industrial', 'social') then
    raise exception 'Choose Residential, Industrial or Social' using errcode = '22023';
  end if;
  update public.squares set kind = p_kind, last_collected_at = now()
  where "row" = p_row and col = p_col and owner = auth.uid() and kind is null;
  if not found then
    raise exception 'That Square already has a type, or isn''t yours' using errcode = 'P0001';
  end if;
end;
$$;

-- ============================================================ mines
-- Each Industrial Square pays 1 point per full day since it last paid out.
-- Points are paid when the member opens QÜBE (the site calls this on load).

alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check (kind in ('spin', 'grant', 'referral', 'post_like', 'mine', 'stake_reward', 'transfer_in', 'transfer_out', 'spend'));

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
    select "row", col, last_collected_at from public.squares
    where owner = v_uid and kind = 'industrial' and last_collected_at <= now() - interval '1 day'
    for update
  loop
    v_days := floor(extract(epoch from (now() - s.last_collected_at)) / 86400)::integer;
    update public.squares set last_collected_at = s.last_collected_at + v_days * interval '1 day'
    where "row" = s."row" and col = s.col;
    v_total := v_total + v_days;
  end loop;
  if v_total > 0 then
    insert into public.ledger (user_id, amount, kind, note)
    values (v_uid, v_total, 'mine', 'Industrial mines · ' || v_total || ' day' || case when v_total = 1 then '' else 's' end);
  end if;
  return v_total;
end;
$$;

-- ============================================================ land market
-- For now the market sells one thing: a new Square, for 100 points.

alter table public.square_grants drop constraint square_grants_reason_check;
alter table public.square_grants add constraint square_grants_reason_check
  check (reason in ('signup', 'referral', 'admin', 'purchase'));

create or replace function public.land_price() returns integer language sql immutable as $$ select 100 $$;

create or replace function public.buy_square()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_balance bigint;
begin
  if not exists (select 1 from public.profiles where id = v_uid and color is not null) then
    raise exception 'Finish your profile first' using errcode = 'P0002';
  end if;
  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));
  select coalesce(sum(amount), 0) into v_balance from public.ledger where user_id = v_uid;
  if v_balance < public.land_price() then
    raise exception 'A Square costs % points. You have %.', public.land_price(), v_balance using errcode = 'P0001';
  end if;
  insert into public.ledger (user_id, amount, kind, note) values (v_uid, -public.land_price(), 'spend', 'Bought a Square');
  insert into public.square_grants (user_id, reason) values (v_uid, 'purchase');
  return v_balance - public.land_price();
end;
$$;

-- ============================================================ Social post slots
-- Each Social Square holds 9 top-level posts. Replies don't use slots.
-- Posts fill a member's Social Squares in order: oldest Square first.

create or replace function public.post_slots(p_uid uuid)
returns table (used bigint, total bigint)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from public.posts where author = p_uid and parent_id is null),
    9 * (select count(*) from public.squares where owner = p_uid and kind = 'social')
$$;

create or replace function public.enforce_post_slots()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_used bigint; v_total bigint;
begin
  if new.parent_id is not null then return new; end if;
  select used, total into v_used, v_total from public.post_slots(new.author);
  if v_total = 0 then
    raise exception 'You need a Social Square to post. Place one on the Sfere.' using errcode = 'P0001';
  end if;
  if v_used >= v_total then
    raise exception 'Your Social Squares are full (% of % posts). Place another Social Square to post more.', v_used, v_total using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger posts_need_social_slots before insert on public.posts
  for each row execute function public.enforce_post_slots();

-- ============================================================ reads

drop function if exists public.sfere_squares();

-- Every claimed Square with its owner's handle and color, its type, and for
-- Social Squares how many of its 9 slots hold posts.
create or replace function public.sfere_squares()
returns table ("row" integer, col integer, handle text, color text, kind text, posts integer, claimed_at timestamptz)
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
         s.claimed_at
  from public.squares s
  join public.profiles p on p.id = s.owner
  left join social so on so."row" = s."row" and so.col = s.col
  left join counts c on c.author = s.owner
$$;

-- The posts shown inside one Social Square (up to 9), oldest first.
create or replace function public.square_posts(p_row integer, p_col integer)
returns table (id bigint, body text, media_url text, media_type text, like_count integer, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with sq as (
    select owner,
           (select count(*) from public.squares o
            where o.owner = s.owner and o.kind = 'social'
              and (o.claimed_at, o."row", o.col) < (s.claimed_at, s."row", s.col)) as idx
    from public.squares s where s."row" = p_row and s.col = p_col and s.kind = 'social'
  )
  select p.id, p.body, p.media_url, p.media_type, p.like_count, p.created_at
  from sq
  join lateral (
    select * from public.posts
    where author = sq.owner and parent_id is null
    order by created_at, id
    offset 9 * sq.idx limit 9
  ) p on true
  order by p.created_at, p.id
$$;

drop function if exists public.my_wallet();

create or replace function public.my_wallet()
returns table (id uuid, handle text, color text, profile_complete boolean, balance bigint, joined_at timestamptz,
               spun_today integer, next_spin_at timestamptz, squares_owned bigint, squares_available bigint,
               invited_by_handle text, industrial bigint, social bigint, residential bigint, unset bigint,
               posts_used bigint, post_slots bigint, next_mine_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id, p.handle, p.color, p.color is not null,
    coalesce((select sum(l.amount) from public.ledger l where l.user_id = p.id), 0)::bigint,
    p.created_at,
    (select s.amount from public.spins s where s.user_id = p.id and s.day = (now() at time zone 'utc')::date),
    (((now() at time zone 'utc')::date + 1)::timestamp at time zone 'utc'),
    (select count(*) from public.squares q where q.owner = p.id),
    (select count(*) from public.square_grants g where g.user_id = p.id) - (select count(*) from public.squares q where q.owner = p.id),
    (select i.handle from public.profiles i where i.id = p.invited_by),
    (select count(*) from public.squares q where q.owner = p.id and q.kind = 'industrial'),
    (select count(*) from public.squares q where q.owner = p.id and q.kind = 'social'),
    (select count(*) from public.squares q where q.owner = p.id and q.kind = 'residential'),
    (select count(*) from public.squares q where q.owner = p.id and q.kind is null),
    (select count(*) from public.posts x where x.author = p.id and x.parent_id is null),
    9 * (select count(*) from public.squares q where q.owner = p.id and q.kind = 'social'),
    (select min(q.last_collected_at) + interval '1 day' from public.squares q where q.owner = p.id and q.kind = 'industrial')
  from public.profiles p
  where p.id = auth.uid();
$$;

-- Public colors for avatars and posts on the Line.
drop function if exists public.line_feed(bigint, integer);
create or replace function public.line_feed(p_before bigint default null, p_limit integer default 30)
returns table (id bigint, author_id uuid, handle text, color text, body text, media_url text, media_type text,
               like_count integer, reply_count integer, created_at timestamptz, liked boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.author, pr.handle, pr.color, p.body, p.media_url, p.media_type, p.like_count, p.reply_count, p.created_at,
         exists (select 1 from public.likes l where l.post_id = p.id and l.user_id = auth.uid())
  from public.posts p join public.profiles pr on pr.id = p.author
  where p.parent_id is null and (p_before is null or p.id < p_before)
  order by p.id desc
  limit least(greatest(p_limit, 1), 50);
$$;

drop function if exists public.line_thread(bigint);
create or replace function public.line_thread(p_id bigint)
returns table (id bigint, parent_id bigint, author_id uuid, handle text, color text, body text, media_url text, media_type text,
               like_count integer, reply_count integer, created_at timestamptz, liked boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.parent_id, p.author, pr.handle, pr.color, p.body, p.media_url, p.media_type, p.like_count, p.reply_count, p.created_at,
         exists (select 1 from public.likes l where l.post_id = p.id and l.user_id = auth.uid())
  from public.posts p join public.profiles pr on pr.id = p.author
  where p.id = p_id or p.parent_id = p_id
  order by (p.id = p_id) desc, p.created_at, p.id
  limit 201;
$$;

-- ============================================================ $POINTS stats

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
    (select count(*) from public.squares where kind = 'industrial'),
    (select count(*) from public.squares),
    public.land_price(),
    -- Total supply at the end of each of the last 30 days (UTC).
    (select jsonb_agg(jsonb_build_object('day', d::date, 'supply', coalesce((
        select sum(amount) from public.ledger where created_at < d + interval '1 day'), 0)) order by d)
     from generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day') d)
$$;

-- The caller's balance at the end of each of the last 30 days.
create or replace function public.my_points_series()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_agg(jsonb_build_object('day', d::date, 'balance', coalesce((
      select sum(amount) from public.ledger where user_id = auth.uid() and created_at < d + interval '1 day'), 0)) order by d)
  from generate_series((now() at time zone 'utc')::date - 29, (now() at time zone 'utc')::date, interval '1 day') d
$$;

-- ============================================================ permissions

revoke all on function public.complete_profile(text, date, text) from public, anon;
revoke all on function public.claim_square(integer, integer, text) from public, anon;
revoke all on function public.set_square_kind(integer, integer, text) from public, anon;
revoke all on function public.collect_mines() from public, anon;
revoke all on function public.buy_square() from public, anon;
revoke all on function public.my_wallet() from public, anon;
revoke all on function public.my_points_series() from public, anon;
revoke all on function public.post_slots(uuid) from public, anon, authenticated;
revoke all on function public.enforce_post_slots() from public, anon, authenticated;
grant execute on function public.complete_profile(text, date, text) to authenticated;
grant execute on function public.claim_square(integer, integer, text) to authenticated;
grant execute on function public.set_square_kind(integer, integer, text) to authenticated;
grant execute on function public.collect_mines() to authenticated;
grant execute on function public.buy_square() to authenticated;
grant execute on function public.my_wallet() to authenticated;
grant execute on function public.my_points_series() to authenticated;
grant execute on function public.sfere_squares() to anon, authenticated;
grant execute on function public.square_posts(integer, integer) to anon, authenticated;
grant execute on function public.line_feed(bigint, integer) to anon, authenticated;
grant execute on function public.line_thread(bigint) to anon, authenticated;
grant execute on function public.points_stats() to anon, authenticated;
grant execute on function public.qube_colors() to anon, authenticated;
grant execute on function public.sfere_cell(double precision, double precision) to anon, authenticated;
