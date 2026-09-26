-- QÜBE: complete database setup, generated from 001_points.sql, 002_sfere_invites.sql and 003_line.sql.
-- Paste all of it into Supabase → SQL Editor → New query, and click Run. Run it once, on a new project.

begin;

-- ======================================================================= 001_points.sql

-- QÜBE points: profiles, an append-only points ledger, and the daily spin.
-- Run once in the Supabase dashboard: SQL Editor → New query → paste → Run.
--
-- Points are off-chain for now. Every change to a balance is a row in
-- public.ledger; a balance is the sum of a user's rows. Clients can read
-- their own rows but never write them. Writes happen only inside the
-- security-definer functions below, so amounts are decided server-side.

-- ---------------------------------------------------------------- profiles

create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  handle      text not null,
  created_at  timestamptz not null default now(),
  constraint handle_format check (handle ~ '^[a-z0-9_]{3,20}$')
);

create unique index profiles_handle_key on public.profiles (handle);

alter table public.profiles enable row level security;

create policy "read own profile"
  on public.profiles for select
  using (id = auth.uid());

-- ------------------------------------------------------------------ ledger

create table public.ledger (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  amount      integer not null check (amount <> 0),
  kind        text not null check (kind in ('spin', 'grant', 'stake_reward', 'transfer_in', 'transfer_out', 'spend')),
  note        text,
  created_at  timestamptz not null default now()
);

create index ledger_user_created_idx on public.ledger (user_id, created_at desc);

alter table public.ledger enable row level security;

create policy "read own ledger"
  on public.ledger for select
  using (user_id = auth.uid());

-- -------------------------------------------------------------- daily spin

-- One row per user per UTC day. The primary key is what enforces
-- "one free spin a day", even under concurrent requests.
create table public.spins (
  user_id  uuid not null references public.profiles (id) on delete cascade,
  day      date not null,
  amount   integer not null,
  primary key (user_id, day)
);

alter table public.spins enable row level security;

create policy "read own spins"
  on public.spins for select
  using (user_id = auth.uid());

-- Prize table. Weights are relative; edit freely.
-- Expected value with these weights is about 33 points a spin.
create table public.spin_prizes (
  amount  integer primary key check (amount > 0),
  weight  integer not null check (weight > 0)
);

insert into public.spin_prizes (amount, weight) values
  (5,    350),
  (10,   250),
  (25,   180),
  (50,   120),
  (100,   70),
  (250,   25),
  (1000,   5);

alter table public.spin_prizes enable row level security;

create policy "anyone can read prizes"
  on public.spin_prizes for select
  using (true);

-- --------------------------------------------------------------- functions

-- Claim a handle after the first sign-in. Creates the profile.
create or replace function public.claim_handle(p_handle text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_handle text := lower(trim(p_handle));
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Handles are 3–20 characters: letters, numbers and underscores' using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'You already have a handle' using errcode = '23505';
  end if;
  if exists (select 1 from public.profiles where handle = v_handle) then
    raise exception 'That handle is taken' using errcode = '23505';
  end if;

  insert into public.profiles (id, handle) values (v_uid, v_handle)
  returning * into v_row;
  return v_row;
end;
$$;

-- Everything the wallet screen needs in one call.
create or replace function public.my_wallet()
returns table (handle text, balance bigint, joined_at timestamptz, spun_today integer, next_spin_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.handle,
    coalesce((select sum(l.amount) from public.ledger l where l.user_id = p.id), 0)::bigint,
    p.created_at,
    (select s.amount from public.spins s where s.user_id = p.id and s.day = (now() at time zone 'utc')::date),
    (((now() at time zone 'utc')::date + 1)::timestamp at time zone 'utc')
  from public.profiles p
  where p.id = auth.uid();
$$;

-- The daily spin. The server picks the prize; the client only animates it.
create or replace function public.spin()
returns table (amount integer, balance bigint)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'utc')::date;
  v_total integer;
  v_roll integer;
  v_amount integer;
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Pick a handle first' using errcode = 'P0002';
  end if;

  select sum(weight) into v_total from public.spin_prizes;
  v_roll := floor(random() * v_total)::integer;

  select p.amount into v_amount
  from (
    select sp.amount, sum(sp.weight) over (order by sp.amount) as upto
    from public.spin_prizes sp
  ) p
  where p.upto > v_roll
  order by p.amount
  limit 1;

  begin
    insert into public.spins (user_id, day, amount) values (v_uid, v_today, v_amount);
  exception when unique_violation then
    raise exception 'You already spun today' using errcode = 'P0001';
  end;

  insert into public.ledger (user_id, amount, kind, note)
  values (v_uid, v_amount, 'spin', 'Daily spin');

  return query
    select v_amount, coalesce(sum(l.amount), 0)::bigint
    from public.ledger l where l.user_id = v_uid;
end;
$$;

-- Lock the functions down to signed-in users.
revoke all on function public.claim_handle(text) from public, anon;
revoke all on function public.my_wallet() from public, anon;
revoke all on function public.spin() from public, anon;
grant execute on function public.claim_handle(text) to authenticated;
grant execute on function public.my_wallet() to authenticated;
grant execute on function public.spin() to authenticated;

-- Clients read through RLS; they never write tables directly.
revoke insert, update, delete on public.profiles, public.ledger, public.spins, public.spin_prizes from anon, authenticated;

-- ======================================================================= 002_sfere_invites.sql

-- QÜBE: invite-only signup, Squares on the Sfere, and referral rewards.
-- Run after 001_points.sql, in the SQL Editor.
--
-- The Sfere grid: the globe is cut into 1,243 bands of latitude, each
-- 10 miles tall. Band r is cut into sfere_cols(r) Squares, each about
-- 10 miles wide. A Square is addressed by (row, col). The same math lives in
-- qube.js so the globe and the database always agree.
--
-- Referral rewards (only when an invited person finishes signing up):
--   level 1  you invited them          → you get 1 free Square (up to 10: one per invite)
--   level 2  someone you invited did   → you get 100 points
--   level 3  one level further down    → you get 10 points
--   level 4+                           → nothing
-- Each level pays a tenth of the one above it, and a person has at most 10
-- invites, so each level's maximum total is the same as the level above,
-- and the whole tree is capped: 10 Squares + 10,000 + 10,000 points.

-- ------------------------------------------------------------------ grid

create or replace function public.sfere_rows()
returns integer language sql immutable as $$ select 1243 $$;

create or replace function public.sfere_cols(p_row integer)
returns integer language sql immutable as $$
  select greatest(1, round(24901 * cos(radians(-90 + (p_row + 0.5) * 180.0 / 1243)) / 10))::integer
$$;

-- ------------------------------------------------------- profile changes

alter table public.profiles
  add column invited_by uuid references public.profiles (id) on delete set null;

create index profiles_invited_by_idx on public.profiles (invited_by);

alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check (kind in ('spin', 'grant', 'referral', 'stake_reward', 'transfer_in', 'transfer_out', 'spend'));

-- ---------------------------------------------------------------- invites

create table public.invites (
  code        text primary key check (code ~ '^[A-Z0-9-]{4,32}$'),
  inviter     uuid references public.profiles (id) on delete cascade,  -- null = founder invite made by an admin
  created_at  timestamptz not null default now(),
  used_by     uuid unique references public.profiles (id) on delete set null,
  used_at     timestamptz
);

create index invites_inviter_idx on public.invites (inviter);
alter table public.invites enable row level security;
-- No policies: invites are only reached through the functions below.

-- ---------------------------------------------------------------- squares

-- Every Square a user is allowed to claim. Available = grants − owned.
create table public.square_grants (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  reason       text not null check (reason in ('signup', 'referral', 'admin')),
  source_user  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

create index square_grants_user_idx on public.square_grants (user_id);
create unique index square_grants_one_per_referral on public.square_grants (user_id, source_user) where reason = 'referral';
alter table public.square_grants enable row level security;
create policy "read own grants" on public.square_grants for select using (user_id = auth.uid());

create table public.squares (
  "row"       integer not null,
  col         integer not null,
  owner       uuid not null references public.profiles (id) on delete cascade,
  claimed_at  timestamptz not null default now(),
  primary key ("row", col),
  constraint square_in_grid check ("row" >= 0 and "row" < 1243 and col >= 0 and col < public.sfere_cols("row"))
);

create index squares_owner_idx on public.squares (owner);
alter table public.squares enable row level security;
create policy "squares are public" on public.squares for select using (true);

revoke insert, update, delete on public.invites, public.square_grants, public.squares from anon, authenticated;

-- ------------------------------------------------------------- functions

-- Lets the join page check a code before sending the sign-in email.
create or replace function public.check_invite(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.invites where code = upper(trim(p_code)) and used_by is null)
$$;

-- Sign-up now needs an unused invite. Replaces the version from 001.
drop function if exists public.claim_handle(text);

create or replace function public.claim_handle(p_handle text, p_invite text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_handle text := lower(trim(p_handle));
  v_code text := upper(trim(p_invite));
  v_inviter uuid;
  v_l2 uuid;
  v_l3 uuid;
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Handles are 3–20 characters: letters, numbers and underscores' using errcode = '22023';
  end if;
  if exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'You already have a handle' using errcode = '23505';
  end if;

  -- Lock the invite so two people can't use it at the same moment.
  select inviter into v_inviter
  from public.invites
  where code = v_code and used_by is null
  for update;
  if not found then
    raise exception 'That invite code is invalid or already used' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.profiles where handle = v_handle) then
    raise exception 'That handle is taken' using errcode = '23505';
  end if;

  insert into public.profiles (id, handle, invited_by)
  values (v_uid, v_handle, v_inviter)
  returning * into v_row;

  update public.invites set used_by = v_uid, used_at = now() where code = v_code;

  -- Everyone starts with one Square to place on the Sfere.
  insert into public.square_grants (user_id, reason) values (v_uid, 'signup');

  -- Level 1: the inviter gets a Square (capped at 10 by their 10 invites).
  if v_inviter is not null then
    insert into public.square_grants (user_id, reason, source_user)
    select v_inviter, 'referral', v_uid
    where (select count(*) from public.square_grants g where g.user_id = v_inviter and g.reason = 'referral') < 10;

    -- Level 2: 100 points.
    select invited_by into v_l2 from public.profiles where id = v_inviter;
    if v_l2 is not null then
      insert into public.ledger (user_id, amount, kind, note)
      values (v_l2, 100, 'referral', 'Level 2 referral: @' || v_handle);

      -- Level 3: 10 points. Nothing deeper.
      select invited_by into v_l3 from public.profiles where id = v_l2;
      if v_l3 is not null then
        insert into public.ledger (user_id, amount, kind, note)
        values (v_l3, 10, 'referral', 'Level 3 referral: @' || v_handle);
      end if;
    end if;
  end if;

  return v_row;
end;
$$;

-- The caller's 10 invite codes, created on first call.
create or replace function public.my_invites()
returns table (code text, used_by_handle text, used_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_have integer;
begin
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Pick a handle first' using errcode = 'P0002';
  end if;
  select count(*) into v_have from public.invites where inviter = v_uid;
  while v_have < 10 loop
    begin
      insert into public.invites (code, inviter)
      values (upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), v_uid);
      v_have := v_have + 1;
    exception when unique_violation then
      null; -- vanishingly rare code collision: try again
    end;
  end loop;

  return query
    select i.code, p.handle, i.used_at
    from public.invites i
    left join public.profiles p on p.id = i.used_by
    where i.inviter = v_uid
    order by i.used_at nulls last, i.created_at, i.code;
end;
$$;

-- How far the caller's invites have spread, and what that earned.
create or replace function public.my_network()
returns table (level integer, people bigint, earned_points bigint, earned_squares bigint)
language sql
stable
security definer
set search_path = public
as $$
  with recursive tree as (
    select p.id, 1 as level from public.profiles p where p.invited_by = auth.uid()
    union all
    select p.id, t.level + 1 from public.profiles p join tree t on p.invited_by = t.id where t.level < 3
  )
  select
    l.level,
    (select count(*) from tree t where t.level = l.level),
    case l.level when 1 then 0
      else coalesce((select sum(amount) from public.ledger where user_id = auth.uid() and kind = 'referral' and note like 'Level ' || l.level || '%'), 0)
    end,
    case l.level when 1 then (select count(*) from public.square_grants where user_id = auth.uid() and reason = 'referral') else 0 end
  from (values (1), (2), (3)) as l(level)
$$;

-- Place one of your available Squares on the Sfere.
create or replace function public.claim_square(p_row integer, p_col integer)
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
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Pick a handle first' using errcode = 'P0002';
  end if;
  if p_row < 0 or p_row >= public.sfere_rows() or p_col < 0 or p_col >= public.sfere_cols(p_row) then
    raise exception 'That Square is off the grid' using errcode = '22023';
  end if;

  -- Serialize claims per user so two tabs can't spend the same grant.
  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  select (select count(*) from public.square_grants where user_id = v_uid)
       - (select count(*) from public.squares where owner = v_uid)
  into v_available;
  if v_available <= 0 then
    raise exception 'You have no Squares left to place. Invite someone to earn one.' using errcode = 'P0001';
  end if;

  begin
    insert into public.squares ("row", col, owner) values (p_row, p_col, v_uid) returning * into v_sq;
  exception when unique_violation then
    raise exception 'Someone already owns that Square' using errcode = '23505';
  end;
  return v_sq;
end;
$$;

-- Every claimed Square with its owner's handle, for drawing the globe.
create or replace function public.sfere_squares()
returns table ("row" integer, col integer, handle text, claimed_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select s."row", s.col, p.handle, s.claimed_at
  from public.squares s join public.profiles p on p.id = s.owner
$$;

-- my_wallet() gains Square counts and a stable id for the avatar.
drop function if exists public.my_wallet();

create or replace function public.my_wallet()
returns table (id uuid, handle text, balance bigint, joined_at timestamptz, spun_today integer, next_spin_at timestamptz,
               squares_owned bigint, squares_available bigint, invited_by_handle text)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.handle,
    coalesce((select sum(l.amount) from public.ledger l where l.user_id = p.id), 0)::bigint,
    p.created_at,
    (select s.amount from public.spins s where s.user_id = p.id and s.day = (now() at time zone 'utc')::date),
    (((now() at time zone 'utc')::date + 1)::timestamp at time zone 'utc'),
    (select count(*) from public.squares q where q.owner = p.id),
    (select count(*) from public.square_grants g where g.user_id = p.id)
      - (select count(*) from public.squares q where q.owner = p.id),
    (select i.handle from public.profiles i where i.id = p.invited_by)
  from public.profiles p
  where p.id = auth.uid();
$$;

-- ------------------------------------------------------------ permissions

revoke all on function public.claim_handle(text, text) from public, anon;
revoke all on function public.my_invites() from public, anon;
revoke all on function public.my_network() from public, anon;
revoke all on function public.claim_square(integer, integer) from public, anon;
revoke all on function public.my_wallet() from public, anon;
grant execute on function public.claim_handle(text, text) to authenticated;
grant execute on function public.my_invites() to authenticated;
grant execute on function public.my_network() to authenticated;
grant execute on function public.claim_square(integer, integer) to authenticated;
grant execute on function public.my_wallet() to authenticated;
grant execute on function public.check_invite(text) to anon, authenticated;
grant execute on function public.sfere_squares() to anon, authenticated;
grant execute on function public.sfere_rows() to anon, authenticated;
grant execute on function public.sfere_cols(integer) to anon, authenticated;

-- ------------------------------------------------------------ first invite
-- Invite-only needs a first key. Run this once and sign up with it:
--   insert into public.invites (code) values ('QUBE-FOUNDER');

-- ======================================================================= 003_line.sql

-- QÜBE: the Line, the main feed. Run after 002_sfere_invites.sql.
--
-- Posts are text, an image or a GIF (or text with one of them). A reply is a
-- post with a parent, like a thread. Posting, liking and replying earn
-- nothing. A post's author earns 1 point for every like it gets; if someone
-- takes their like back, that point goes too. Nobody can like their own post,
-- and each person can like a post only once.

alter table public.ledger drop constraint ledger_kind_check;
alter table public.ledger add constraint ledger_kind_check
  check (kind in ('spin', 'grant', 'referral', 'post_like', 'stake_reward', 'transfer_in', 'transfer_out', 'spend'));

-- ------------------------------------------------------------------ posts

create table public.posts (
  id           bigint generated always as identity primary key,
  author       uuid not null references public.profiles (id) on delete cascade,
  parent_id    bigint references public.posts (id) on delete cascade,
  body         text not null default '' check (char_length(body) <= 500),
  media_url    text,
  media_type   text check (media_type in ('image', 'gif')),
  like_count   integer not null default 0,
  reply_count  integer not null default 0,
  created_at   timestamptz not null default now(),
  constraint post_not_empty check (char_length(trim(body)) > 0 or media_url is not null),
  constraint media_pair check ((media_url is null) = (media_type is null))
);

create index posts_feed_idx on public.posts (created_at desc, id desc) where parent_id is null;
create index posts_parent_idx on public.posts (parent_id, created_at);
create index posts_author_idx on public.posts (author, created_at desc);

create table public.likes (
  post_id     bigint not null references public.posts (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index likes_user_idx on public.likes (user_id);

alter table public.posts enable row level security;
alter table public.likes enable row level security;
create policy "posts are public" on public.posts for select using (true);
create policy "likes are public" on public.likes for select using (true);
revoke insert, update, delete on public.posts, public.likes from anon, authenticated;

-- ------------------------------------------------------------------ media
-- Uploads go to a public bucket, in a folder named after the uploader's id.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('line-media', 'line-media', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

create policy "members upload to their own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'line-media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles where id = auth.uid())
  );

create policy "members delete their own uploads"
  on storage.objects for delete to authenticated
  using (bucket_id = 'line-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- -------------------------------------------------------------- functions

create or replace function public.create_post(p_body text, p_media_url text default null, p_media_type text default null, p_parent_id bigint default null)
returns public.posts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := trim(coalesce(p_body, ''));
  v_post public.posts;
begin
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Only members can post' using errcode = '28000';
  end if;
  if char_length(v_body) > 500 then
    raise exception 'Posts are 500 characters at most' using errcode = '22023';
  end if;
  if v_body = '' and p_media_url is null then
    raise exception 'Write something or add an image' using errcode = '22023';
  end if;
  -- Media must be the poster's own upload in the Line bucket.
  if p_media_url is not null and position('/storage/v1/object/public/line-media/' || v_uid::text || '/' in p_media_url) = 0 then
    raise exception 'That image must be uploaded to QÜBE first' using errcode = '22023';
  end if;
  if (p_media_url is null) <> (p_media_type is null) or (p_media_type is not null and p_media_type not in ('image', 'gif')) then
    raise exception 'Unknown media type' using errcode = '22023';
  end if;
  if p_parent_id is not null and not exists (select 1 from public.posts where id = p_parent_id) then
    raise exception 'That post no longer exists' using errcode = 'P0002';
  end if;
  -- Spam brake: 30 posts and replies an hour.
  if (select count(*) from public.posts where author = v_uid and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You''re posting a lot. Try again in a bit.' using errcode = 'P0001';
  end if;

  insert into public.posts (author, parent_id, body, media_url, media_type)
  values (v_uid, p_parent_id, v_body, p_media_url, p_media_type)
  returning * into v_post;

  if p_parent_id is not null then
    update public.posts set reply_count = reply_count + 1 where id = p_parent_id;
  end if;
  return v_post;
end;
$$;

create or replace function public.delete_post(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_parent bigint;
begin
  delete from public.posts where id = p_id and author = auth.uid() returning parent_id into v_parent;
  if not found then
    raise exception 'You can only delete your own posts' using errcode = '42501';
  end if;
  if v_parent is not null then
    update public.posts set reply_count = greatest(0, reply_count - 1) where id = v_parent;
  end if;
end;
$$;

-- Like: +1 point to the author. Returns the new like count.
create or replace function public.like_post(p_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_count integer;
begin
  if not exists (select 1 from public.profiles where id = v_uid) then
    raise exception 'Only members can like posts' using errcode = '28000';
  end if;
  select author into v_author from public.posts where id = p_id for update;
  if not found then
    raise exception 'That post no longer exists' using errcode = 'P0002';
  end if;
  if v_author = v_uid then
    raise exception 'You can''t like your own post' using errcode = 'P0001';
  end if;

  begin
    insert into public.likes (post_id, user_id) values (p_id, v_uid);
  exception when unique_violation then
    raise exception 'You already liked this' using errcode = '23505';
  end;

  update public.posts set like_count = like_count + 1 where id = p_id returning like_count into v_count;
  insert into public.ledger (user_id, amount, kind, note) values (v_author, 1, 'post_like', 'Like on your post #' || p_id);
  return v_count;
end;
$$;

-- Unlike: the author loses the point that like gave them.
create or replace function public.unlike_post(p_id bigint)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_count integer;
begin
  select author into v_author from public.posts where id = p_id for update;
  if not found then
    raise exception 'That post no longer exists' using errcode = 'P0002';
  end if;
  delete from public.likes where post_id = p_id and user_id = v_uid;
  if not found then
    raise exception 'You haven''t liked this' using errcode = 'P0002';
  end if;
  update public.posts set like_count = greatest(0, like_count - 1) where id = p_id returning like_count into v_count;
  insert into public.ledger (user_id, amount, kind, note) values (v_author, -1, 'post_like', 'Like removed from post #' || p_id);
  return v_count;
end;
$$;

-- Top-level posts, newest first. Pass the last id you have to page back.
create or replace function public.line_feed(p_before bigint default null, p_limit integer default 30)
returns table (id bigint, author_id uuid, handle text, body text, media_url text, media_type text,
               like_count integer, reply_count integer, created_at timestamptz, liked boolean)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.author, pr.handle, p.body, p.media_url, p.media_type, p.like_count, p.reply_count, p.created_at,
         exists (select 1 from public.likes l where l.post_id = p.id and l.user_id = auth.uid())
  from public.posts p
  join public.profiles pr on pr.id = p.author
  where p.parent_id is null and (p_before is null or p.id < p_before)
  order by p.id desc
  limit least(greatest(p_limit, 1), 50);
$$;

-- One post and its replies, oldest reply first.
create or replace function public.line_thread(p_id bigint)
returns table (id bigint, parent_id bigint, author_id uuid, handle text, body text, media_url text, media_type text,
               like_count integer, reply_count integer, created_at timestamptz, liked boolean)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.parent_id, p.author, pr.handle, p.body, p.media_url, p.media_type, p.like_count, p.reply_count, p.created_at,
         exists (select 1 from public.likes l where l.post_id = p.id and l.user_id = auth.uid())
  from public.posts p
  join public.profiles pr on pr.id = p.author
  where p.id = p_id or p.parent_id = p_id
  order by (p.id = p_id) desc, p.created_at, p.id
  limit 201;
$$;

revoke all on function public.create_post(text, text, text, bigint) from public, anon;
revoke all on function public.delete_post(bigint) from public, anon;
revoke all on function public.like_post(bigint) from public, anon;
revoke all on function public.unlike_post(bigint) from public, anon;
grant execute on function public.create_post(text, text, text, bigint) to authenticated;
grant execute on function public.delete_post(bigint) to authenticated;
grant execute on function public.like_post(bigint) to authenticated;
grant execute on function public.unlike_post(bigint) to authenticated;
grant execute on function public.line_feed(bigint, integer) to anon, authenticated;
grant execute on function public.line_thread(bigint) to anon, authenticated;

commit;
