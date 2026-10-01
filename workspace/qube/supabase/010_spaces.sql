-- QÜBE: Spaces. Every Square is a place you can enter.
-- Run once, after 009. SQL Editor → New query → paste → Run.
--
-- A Space has up to 9 rooms. Each room is a 9 × 9 floor, up to 9 blocks high, described
-- by a small JSON document (format "qube-space/1"):
--   { "v": 1, "blocks": [ { "t": "brick", "x": 0, "y": 0, "z": 0, "c": "#3a3df5" }, … ] }
-- Owners edit a draft for free; publishing charges points for what's new (they go to the
-- Central Bank) and makes the room visible to everyone. Rearranging is free.
-- The Space belongs to whoever owns the Square, so it goes with the Square when sold.

-- ============================================================ tables

create table if not exists public.spaces (
  "row"          integer not null,
  col            integer not null,
  title          text check (char_length(title) <= 48),
  agent_publish  text not null default 'draft' check (agent_publish in ('draft', 'auto')),
  visits         integer not null default 0,
  updated_at     timestamptz not null default now(),
  primary key ("row", col)
);

create table if not exists public.space_rooms (
  id          bigint generated always as identity primary key,
  "row"       integer not null,
  col         integer not null,
  slug        text not null check (slug ~ '^[a-z0-9-]{1,24}$'),
  name        text not null check (char_length(name) between 1 and 32),
  position    integer not null default 0,
  draft       jsonb not null default '{"v": 1, "blocks": []}',
  published   jsonb,
  paid        integer not null default 0,   -- points already paid for this room's blocks
  room_paid   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique ("row", col, slug)
);
create index if not exists space_rooms_square_idx on public.space_rooms ("row", col, position);

create table if not exists public.space_guestbook (
  id          bigint generated always as identity primary key,
  "row"       integer not null,
  col         integer not null,
  author      uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (char_length(trim(body)) between 1 and 140),
  created_at  timestamptz not null default now()
);
create index if not exists space_guestbook_idx on public.space_guestbook ("row", col, created_at desc);

alter table public.spaces enable row level security;
alter table public.space_rooms enable row level security;
alter table public.space_guestbook enable row level security;
-- No policies: everything goes through the functions below.

-- ============================================================ blocks

-- What each block costs to publish, in points. Unknown types aren't allowed.
create or replace function public.space_block_cost(p_type text) returns integer
language sql immutable as $$
  select case p_type
    when 'brick' then 1  when 'paint' then 1  when 'water' then 2
    when 'plant' then 3  when 'berrybush' then 3
    when 'light' then 5  when 'shape' then 5
    when 'sign' then 10  when 'frame' then 10 when 'guestbook' then 10 when 'tipjar' then 10
    when 'board' then 15 when 'portal' then 25
    else null end
$$;

create or replace function public.space_room_price() returns integer language sql immutable as $$ select 50 $$;

create or replace function public.space_layout_cost(p_layout jsonb) returns integer
language sql immutable as $$
  select coalesce(sum(public.space_block_cost(b->>'t')), 0)::integer
  from jsonb_array_elements(coalesce(p_layout->'blocks', '[]'::jsonb)) b
$$;

-- Checks a room document; raises with a plain message when something's off.
create or replace function public.space_check_layout(p_layout jsonb, p_owner uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b jsonb;
  n integer := 0;
  t text;
  x integer; y integer; z integer;
  cells text[] := '{}';
  key text;
begin
  if jsonb_typeof(p_layout) <> 'object' or jsonb_typeof(p_layout->'blocks') <> 'array' then
    raise exception 'That room couldn''t be read' using errcode = '22023';
  end if;
  if octet_length(p_layout::text) > 120000 then
    raise exception 'That room is too big to save' using errcode = '22023';
  end if;
  for b in select * from jsonb_array_elements(p_layout->'blocks') loop
    n := n + 1;
    if n > 600 then raise exception 'A room holds up to 600 blocks' using errcode = '22023'; end if;
    t := b->>'t';
    if public.space_block_cost(t) is null then raise exception 'Unknown block "%"', t using errcode = '22023'; end if;
    x := (b->>'x')::integer; y := (b->>'y')::integer; z := coalesce((b->>'z')::integer, 0);
    if x is null or y is null or x < 0 or x > 8 or y < 0 or y > 8 or z < 0 or z > 8 then
      raise exception 'Blocks stay inside the 9 × 9 × 9 room' using errcode = '22023';
    end if;
    -- floor layers (paint, water) and things standing in a cell can't overlap their own kind
    key := case when t in ('paint', 'water') then 'f' else 's' end || x || '.' || y || '.' || case when t in ('paint', 'water') then 0 else z end;
    if key = any (cells) then raise exception 'Two blocks can''t share one spot' using errcode = '22023'; end if;
    cells := cells || key;
    if b ? 'c' and (b->>'c') !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Colors are #rrggbb' using errcode = '22023'; end if;
    if t = 'sign' and char_length(coalesce(b->>'text', '')) > 40 then raise exception 'Signs hold 40 characters' using errcode = '22023'; end if;
    if t = 'frame' and b ? 'url' and (b->>'url') <> ''
       and position('/storage/v1/object/public/line-media/' || p_owner::text || '/' in (b->>'url')) = 0 then
      raise exception 'Frames show images uploaded from QÜBE' using errcode = '22023';
    end if;
    if t = 'portal' then
      if (b->'to'->>'row') is not null and (((b->'to'->>'row')::integer not between 0 and 3437) or ((b->'to'->>'col')::integer not between 0 and 572)) then
        raise exception 'That portal leads off the Sfere' using errcode = '22023';
      end if;
      if char_length(coalesce(b->>'label', '')) > 32 then raise exception 'Portal labels hold 32 characters' using errcode = '22023'; end if;
    end if;
  end loop;
end;
$$;

-- ============================================================ reading a Space

create or replace function public.space_view(p_row integer, p_col integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_sq record;
  v_owner boolean;
begin
  select s."row", s.col, s.kind, s.mines, s.promo_url, s.owner,
         s.kind = 'agricultural' and (s.last_harvest_on is null or s.last_harvest_on < (now() at time zone 'utc')::date) as ripe,
         p.handle, p.color, ag.name as agent_name
  into v_sq
  from public.squares s
  join public.profiles p on p.id = s.owner
  left join public.agents ag on ag.home_row = s."row" and ag.home_col = s.col
  where s."row" = p_row and s.col = p_col;
  if v_sq."row" is null then return null; end if;
  v_owner := v_uid is not null and v_uid = v_sq.owner;
  if not v_owner then
    update public.spaces set visits = visits + 1 where "row" = p_row and col = p_col;
  end if;

  return jsonb_build_object(
    'row', p_row, 'col', p_col,
    'kind', v_sq.kind, 'mines', v_sq.mines, 'promo_url', v_sq.promo_url, 'ripe', v_sq.ripe,
    'handle', v_sq.handle, 'color', v_sq.color, 'agent_name', v_sq.agent_name,
    'is_owner', v_owner,
    'title', (select title from public.spaces where "row" = p_row and col = p_col),
    'agent_publish', (select agent_publish from public.spaces where "row" = p_row and col = p_col),
    'visits', coalesce((select visits from public.spaces where "row" = p_row and col = p_col), 0),
    'rooms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', r.slug, 'name', r.name,
        'published', r.published,
        'draft', case when v_owner then r.draft end,
        'paid', case when v_owner then r.paid end,
        'room_paid', case when v_owner then r.room_paid end
      ) order by r.position, r.id)
      from public.space_rooms r
      where r."row" = p_row and r.col = p_col and (v_owner or r.published is not null)), '[]'::jsonb),
    'guestbook', coalesce((
      select jsonb_agg(jsonb_build_object('handle', p.handle, 'color', p.color, 'body', g.body, 'at', g.created_at) order by g.created_at desc)
      from (select * from public.space_guestbook where "row" = p_row and col = p_col order by created_at desc limit 30) g
      join public.profiles p on p.id = g.author), '[]'::jsonb),
    'posts', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'body', x.body, 'media_url', x.media_url, 'likes', x.like_count, 'at', x.created_at) order by x.created_at desc)
      from (select * from public.posts where author = v_sq.owner and parent_id is null order by created_at desc limit 3) x), '[]'::jsonb)
  );
end;
$$;

-- ============================================================ building

create or replace function public.space_owner_check(p_row integer, p_col integer) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.squares where "row" = p_row and col = p_col and owner = auth.uid()) then
    raise exception 'Only the Square''s owner can build here' using errcode = '42501';
  end if;
end;
$$;

-- Saves a room's draft (free). Creates the room when it's new; a Space holds 9.
create or replace function public.space_save_draft(p_row integer, p_col integer, p_slug text, p_name text, p_layout jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.space_owner_check(p_row, p_col);
  perform public.space_check_layout(p_layout, auth.uid());
  insert into public.spaces ("row", col) values (p_row, p_col) on conflict do nothing;
  if not exists (select 1 from public.space_rooms where "row" = p_row and col = p_col and slug = p_slug) then
    if (select count(*) from public.space_rooms where "row" = p_row and col = p_col) >= 9 then
      raise exception 'A Space holds 9 rooms' using errcode = 'P0001';
    end if;
    insert into public.space_rooms ("row", col, slug, name, position, draft, room_paid)
    values (p_row, p_col, p_slug, coalesce(nullif(trim(p_name), ''), 'Room'),
            (select coalesce(max(position), -1) + 1 from public.space_rooms where "row" = p_row and col = p_col),
            p_layout, p_slug = 'main');   -- the entrance room comes with the Square
  else
    update public.space_rooms set draft = p_layout, name = coalesce(nullif(trim(p_name), ''), name), updated_at = now()
    where "row" = p_row and col = p_col and slug = p_slug;
  end if;
  update public.spaces set updated_at = now() where "row" = p_row and col = p_col;
end;
$$;

-- What publishing a room's draft would cost right now.
create or replace function public.space_publish_cost(p_row integer, p_col integer, p_slug text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, public.space_layout_cost(r.draft) - r.paid) + case when r.room_paid then 0 else public.space_room_price() end
  from public.space_rooms r where r."row" = p_row and r.col = p_col and r.slug = p_slug
$$;

create or replace function public.space_publish(p_row integer, p_col integer, p_slug text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_r public.space_rooms;
  v_cost integer;
  v_balance bigint;
begin
  perform public.space_owner_check(p_row, p_col);
  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));
  select * into v_r from public.space_rooms where "row" = p_row and col = p_col and slug = p_slug for update;
  if v_r.id is null then raise exception 'Save the room first' using errcode = 'P0001'; end if;
  perform public.space_check_layout(v_r.draft, v_uid);
  v_cost := greatest(0, public.space_layout_cost(v_r.draft) - v_r.paid) + case when v_r.room_paid then 0 else public.space_room_price() end;
  if v_cost > 0 then
    select coalesce(sum(amount), 0) into v_balance from public.ledger where user_id = v_uid;
    if v_balance < v_cost then
      raise exception 'Publishing this costs % points. You have %.', v_cost, v_balance using errcode = 'P0001';
    end if;
    insert into public.ledger (user_id, amount, kind, note)
    values (v_uid, -v_cost, 'spend', 'Built in ' || v_r.name || ' (Square ' || p_row || '.' || p_col || ')');
  end if;
  update public.space_rooms
  set published = draft, paid = greatest(paid, public.space_layout_cost(draft)), room_paid = true, updated_at = now()
  where id = v_r.id;
  return v_cost;
end;
$$;

create or replace function public.space_delete_room(p_row integer, p_col integer, p_slug text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.space_owner_check(p_row, p_col);
  if p_slug = 'main' then raise exception 'The entrance stays' using errcode = 'P0001'; end if;
  delete from public.space_rooms where "row" = p_row and col = p_col and slug = p_slug;
end;
$$;

create or replace function public.space_set_title(p_row integer, p_col integer, p_title text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.space_owner_check(p_row, p_col);
  insert into public.spaces ("row", col, title) values (p_row, p_col, nullif(trim(p_title), ''))
  on conflict ("row", col) do update set title = excluded.title, updated_at = now();
end;
$$;

-- ============================================================ visiting

create or replace function public.space_sign_guestbook(p_row integer, p_col integer, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid and color is not null) then
    raise exception 'Members sign guestbooks' using errcode = '42501';
  end if;
  if (select count(*) from public.space_guestbook where author = v_uid and "row" = p_row and col = p_col
      and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You''ve signed this guestbook enough for today' using errcode = 'P0001';
  end if;
  insert into public.space_guestbook ("row", col, author, body) values (p_row, p_col, v_uid, trim(p_body));
end;
$$;

create or replace function public.space_tip(p_row integer, p_col integer, p_amount integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_balance bigint;
begin
  select owner into v_owner from public.squares where "row" = p_row and col = p_col;
  if v_owner is null then raise exception 'Nobody lives here' using errcode = 'P0001'; end if;
  if v_owner = v_uid then raise exception 'You can''t tip yourself' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then raise exception 'Tip between 1 and 10,000 points' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('wallet:' || v_uid::text));
  select coalesce(sum(amount), 0) into v_balance from public.ledger where user_id = v_uid;
  if v_balance < p_amount then raise exception 'You have % points', v_balance using errcode = 'P0001'; end if;
  insert into public.ledger (user_id, amount, kind, note) values (v_uid, -p_amount, 'transfer_out', 'Tip at Square ' || p_row || '.' || p_col);
  insert into public.ledger (user_id, amount, kind, note) values (v_owner, p_amount, 'transfer_in', 'A tip in your Space');
end;
$$;

-- Which Squares have something built, for the Sfere.
create or replace function public.spaces_built()
returns table ("row" integer, col integer)
language sql stable security definer set search_path = public as $$
  select distinct r."row", r.col from public.space_rooms r
  join public.squares s on s."row" = r."row" and s.col = r.col
  where r.published is not null and jsonb_array_length(coalesce(r.published->'blocks', '[]'::jsonb)) > 0
$$;

-- ============================================================ access

revoke all on function public.space_check_layout(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.space_owner_check(integer, integer) from public, anon, authenticated;
revoke all on function public.space_save_draft(integer, integer, text, text, jsonb) from public, anon;
revoke all on function public.space_publish_cost(integer, integer, text) from public, anon;
revoke all on function public.space_publish(integer, integer, text) from public, anon;
revoke all on function public.space_delete_room(integer, integer, text) from public, anon;
revoke all on function public.space_set_title(integer, integer, text) from public, anon;
revoke all on function public.space_sign_guestbook(integer, integer, text) from public, anon;
revoke all on function public.space_tip(integer, integer, integer) from public, anon;
grant execute on function public.space_view(integer, integer) to anon, authenticated;
grant execute on function public.spaces_built() to anon, authenticated;
grant execute on function public.space_block_cost(text) to anon, authenticated;
grant execute on function public.space_save_draft(integer, integer, text, text, jsonb) to authenticated;
grant execute on function public.space_publish_cost(integer, integer, text) to authenticated;
grant execute on function public.space_publish(integer, integer, text) to authenticated;
grant execute on function public.space_delete_room(integer, integer, text) to authenticated;
grant execute on function public.space_set_title(integer, integer, text) to authenticated;
grant execute on function public.space_sign_guestbook(integer, integer, text) to authenticated;
grant execute on function public.space_tip(integer, integer, integer) to authenticated;
