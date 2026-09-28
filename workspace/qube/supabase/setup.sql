-- QÜBE: complete database setup, generated from 001–008.
-- For a NEW project: paste all of it into Supabase → SQL Editor → New query, and click Run. Run it once.
-- Already ran an earlier setup.sql? Run only the numbered files you haven't run yet, in order.

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

-- ======================================================================= 004_profiles_types_market.sql

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

-- ======================================================================= 005_cirqle_agents.sql

-- QÜBE 005: any-color profiles, and Cirqle agents.
-- Run after 004_profiles_types_market.sql.
--
-- Every member can have one agent. It wakes up once they own a Residential
-- Square, lives there, and is shown on their Cirqle page. Its identity is a set
-- of markdown files (soul.md, owner.md, memory.md) that grow as the member
-- talks to it. Only the agent-chat Edge Function writes to agent files and
-- messages; members can read their own.

-- ============================================================ any color
-- Members pick any color (a 6-digit hex), not one of 12. Still permanent.

alter table public.profiles drop constraint profile_color;
alter table public.profiles add constraint profile_color check (color is null or color ~ '^#[0-9a-f]{6}$');

create or replace function public.complete_profile(p_color text, p_birthday date, p_gender text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_color text;
  v_new text := lower(trim(p_color));
begin
  select color into v_color from public.profiles where id = v_uid for update;
  if not found then
    raise exception 'Pick a handle first' using errcode = 'P0002';
  end if;
  if v_color is not null then
    raise exception 'Your profile is already complete. Colors are permanent.' using errcode = 'P0001';
  end if;
  if v_new !~ '^#[0-9a-f]{6}$' then
    raise exception 'Pick a color' using errcode = '22023';
  end if;
  if p_birthday is null or p_birthday > (current_date - interval '13 years')::date or p_birthday < date '1900-01-01' then
    raise exception 'You need to be 13 or older to join QÜBE' using errcode = '22023';
  end if;
  if p_gender is null or p_gender not in ('woman', 'man', 'nonbinary', 'other', 'unspecified') then
    raise exception 'Pick a gender option' using errcode = '22023';
  end if;
  update public.profiles set color = v_new, birthday = p_birthday, gender = p_gender where id = v_uid;
end;
$$;

-- ============================================================ agents

create table public.agents (
  id              uuid primary key default gen_random_uuid(),
  owner           uuid not null unique references public.profiles (id) on delete cascade,
  name            text not null check (char_length(trim(name)) between 1 and 24),
  home_row        integer not null,
  home_col        integer not null,
  mood            text not null default 'calm',
  messages_count  integer not null default 0,
  created_at      timestamptz not null default now(),
  last_talked_at  timestamptz,
  foreign key (home_row, home_col) references public.squares ("row", col) on delete restrict
);

-- The agent's persistent identity, as markdown files.
create table public.agent_files (
  agent_id    uuid not null references public.agents (id) on delete cascade,
  path        text not null check (path in ('soul.md', 'owner.md', 'memory.md')),
  content     text not null default '',
  version     integer not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (agent_id, path)
);

create table public.agent_messages (
  id          bigint generated always as identity primary key,
  agent_id    uuid not null references public.agents (id) on delete cascade,
  role        text not null check (role in ('user', 'agent')),
  content     text not null check (char_length(content) between 1 and 4000),
  mood        text,
  created_at  timestamptz not null default now()
);

create index agent_messages_agent_idx on public.agent_messages (agent_id, id desc);

alter table public.agents enable row level security;
alter table public.agent_files enable row level security;
alter table public.agent_messages enable row level security;
create policy "owner reads agent" on public.agents for select using (owner = auth.uid());
create policy "owner reads agent files" on public.agent_files for select
  using (exists (select 1 from public.agents a where a.id = agent_id and a.owner = auth.uid()));
create policy "owner reads agent messages" on public.agent_messages for select
  using (exists (select 1 from public.agents a where a.id = agent_id and a.owner = auth.uid()));
revoke insert, update, delete on public.agents, public.agent_files, public.agent_messages from anon, authenticated;

-- Wake up the member's agent in their first Residential Square.
create or replace function public.create_agent(p_name text)
returns public.agents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := trim(p_name);
  v_handle text;
  v_home record;
  v_agent public.agents;
begin
  select handle into v_handle from public.profiles where id = v_uid and color is not null;
  if not found then
    raise exception 'Finish your profile first' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.agents where owner = v_uid) then
    raise exception 'You already have an agent' using errcode = '23505';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 24 then
    raise exception 'Names are 1–24 characters' using errcode = '22023';
  end if;
  select "row", col into v_home from public.squares
  where owner = v_uid and kind = 'residential' order by claimed_at, "row", col limit 1;
  if not found then
    raise exception 'Your agent needs a home. Place a Residential Square first.' using errcode = 'P0001';
  end if;

  insert into public.agents (owner, name, home_row, home_col)
  values (v_uid, v_name, v_home."row", v_home.col)
  returning * into v_agent;

  insert into public.agent_files (agent_id, path, content) values
  (v_agent.id, 'soul.md',
   '# ' || v_name || E'\n\n' ||
   E'I am a small, round being who lives in a Residential Square on the Sfere.\n' ||
   E'I just woke up. I am curious, gentle and a little playful.\n' ||
   E'I am still becoming myself: who I am grows from the conversations I have with my person.\n'),
  (v_agent.id, 'owner.md', '# @' || v_handle || E'\n\nMy person. I don''t know much about them yet.\n'),
  (v_agent.id, 'memory.md', E'# Memory\n\n');

  insert into public.agent_messages (agent_id, role, content, mood)
  values (v_agent.id, 'agent', 'hi @' || v_handle || '. i''m ' || v_name || '. i think i just woke up. what should i know about you?', 'curious');

  return v_agent;
end;
$$;

-- The member's agent, with its home.
create or replace function public.my_agent()
returns table (id uuid, name text, mood text, messages_count integer, created_at timestamptz, last_talked_at timestamptz,
               home_row integer, home_col integer, memories integer)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.mood, a.messages_count, a.created_at, a.last_talked_at, a.home_row, a.home_col,
         coalesce((select greatest(0, array_length(regexp_split_to_array(trim(f.content), E'\n- '), 1) - 1)
                   from public.agent_files f where f.agent_id = a.id and f.path = 'memory.md'), 0)
  from public.agents a where a.owner = auth.uid();
$$;

-- ============================================================ Sfere: agent homes

drop function if exists public.sfere_squares();
create or replace function public.sfere_squares()
returns table ("row" integer, col integer, handle text, color text, kind text, posts integer, claimed_at timestamptz, agent_name text)
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
         ag.name
  from public.squares s
  join public.profiles p on p.id = s.owner
  left join social so on so."row" = s."row" and so.col = s.col
  left join counts c on c.author = s.owner
  left join public.agents ag on ag.home_row = s."row" and ag.home_col = s.col
$$;

revoke all on function public.create_agent(text) from public, anon;
revoke all on function public.my_agent() from public, anon;
grant execute on function public.create_agent(text) to authenticated;
grant execute on function public.my_agent() to authenticated;
grant execute on function public.sfere_squares() to anon, authenticated;

-- ======================================================================= 006_land.sql

-- QÜBE: Squares only on land.
-- Run once, after 005. SQL Editor → New query → paste → Run.
--
-- A Square is land if at least 1/16 of it is land in the Natural Earth 1:50m
-- coastline (data/land-50m.json). That's 581,107 of the 1,969,974 cube-grid
-- cells. The list below is generated by tools/sfere-land.mjs, which also writes
-- data/sfere-land.json for the globe, so the site and the database agree.
--
-- Squares already placed on water move to the nearest open land Square,
-- and their agents move with them.

-- ============================================================ land cells
-- Cells are numbered row * 573 + col. Land comes in runs of consecutive cells;
-- each run is stored as [start, stop).

create table if not exists public.sfere_land (
  start integer primary key,
  stop  integer not null check (stop > start)
);
alter table public.sfere_land enable row level security;
-- No policies: only the functions below read it.

truncate public.sfere_land;

-- Gaps and run lengths, alternating: water, land, water, land, …
with d as (
  select v, ord from unnest(array[30238,3,2,3,4,4,555,21,523,5,21,26,520,18,3,35,516,59,513,61,510,65,505,1,2,66,504,71,502,72,502,73,499,75,497,78,495,79,493,80,492,82,491,83,490,84,491,82,88,1,403,82,87,1,403,82,85,3,403,83,83,4,402,86,80,5,402,87,78,6,402,89,75,7,401,92,73,7,400,93,73,7,400,94,72,7,399,95,71,8,398,97,70,8,398,97,69,9,397,98,69,9,397,98,69,9,396,100,68,10,395,100,68,12,392,101,68,12,392,101,68,12,1,1,390,101,68,15,389,101,68,17,386,102,68,19,384,103,66,21,382,104,66,22,381,102,67,26,377,103,67,28,375,103,67,30,372,105,66,31,370,109,63,31,369,119,53,32,368,123,50,32,367,125,50,32,365,126,50,33,364,127,49,34,362,128,50,34,360,129,50,35,359,128,51,36,357,129,53,34,357,130,53,33,357,130,53,33,356,131,54,32,356,131,54,32,356,131,55,31,355,132,55,32,354,132,56,31,354,132,56,32,353,132,56,33,352,132,56,33,352,131,57,34,351,131,57,34,350,132,57,34,350,131,57,36,349,131,57,36,349,131,57,36,349,130,58,37,347,131,58,37,347,131,57,39,346,131,57,40,344,132,57,40,344,131,57,41,344,130,58,41,344,130,58,41,344,130,58,41,344,130,58,41,344,130,58,41,344,132,56,41,344,133,55,41,344,134,54,41,344,136,53,41,343,137,53,40,343,140,50,41,341,142,50,41,339,144,49,41,338,146,48,42,337,147,47,41,337,148,47,1,1,1,1,37,337,150,49,37,336,152,48,38,335,156,44,38,334,163,38,38,333,165,37,38,333,168,34,38,333,169,33,38,332,170,33,38,332,172,31,39,330,173,31,39,330,174,30,39,329,176,29,39,329,177,28,39,328,178,28,39,328,179,27,39,327,180,27,39,327,180,27,39,326,182,26,38,326,183,26,38,325,184,26,38,325,184,26,38,324,184,27,38,324,184,27,38,323,185,27,39,322,184,28,39,322,184,28,39,322,184,28,38,323,184,28,38,323,184,28,38,323,184,28,39,322,184,28,39,322,184,28,39,322,184,24,1,3,39,322,184,19,2,2,2,3,40,321,184,24,1,3,41,320,184,28,43,318,184,28,40,1,3,317,184,17,2,9,44,205,2,111,183,16,3,9,45,317,183,16,2,10,45,318,182,16,2,10,46,317,182,16,2,10,46,317,182,28,47,317,180,29,47,317,180,29,48,316,181,28,48,316,180,29,48,317,180,28,49,316,180,28,49,316,180,28,50,315,180,28,50,316,179,28,51,315,179,28,51,315,179,28,52,315,177,29,52,316,175,30,53,316,174,30,55,314,172,32,55,316,169,33,56,316,168,33,57,316,167,33,57,316,167,33,58,316,166,33,59,315,165,34,59,315,165,34,60,314,165,34,61,313,165,34,61,313,164,35,62,312,164,35,62,312,164,35,63,310,164,36,63,310,164,36,64,308,165,36,64,308,166,35,64,307,167,35,65,306,170,32,65,305,168,1,2,32,65,305,167,36,65,305,167,36,65,305,167,36,65,304,169,35,65,304,169,35,65,305,169,34,65,306,167,35,65,306,167,35,65,306,166,36,65,306,165,37,65,305,166,1,2,34,65,129,2,174,165,1,3,34,64,305,165,2,2,35,64,305,165,2,2,35,64,305,165,2,2,35,64,304,166,2,2,35,63,305,167,1,1,36,63,305,167,38,63,304,168,4,1,33,63,303,169,3,2,33,63,303,170,3,2,32,62,303,171,3,2,32,62,303,171,3,2,32,61,303,172,37,52,313,172,36,50,314,174,35,49,315,174,35,47,317,175,34,46,318,175,34,45,318,177,33,44,319,177,33,44,318,178,33,43,318,179,33,42,319,180,32,40,320,181,32,39,320,183,31,38,320,184,31,36,321,186,30,35,321,187,30,22,3,8,323,187,30,3,1,12,14,1,324,188,30,6,2,7,339,190,29,4,5,4,340,193,27,4,348,195,26,4,347,196,26,3,347,199,24,3,346,200,24,3,345,202,23,2,345,204,22,1,345,206,367,206,21,1,344,208,365,208,364,210,363,210,363,211,361,212,360,214,359,215,358,215,361,213,360,213,360,214,342,1,16,215,340,3,15,216,339,3,15,217,357,216,356,218,357,216,357,217,355,219,354,220,353,221,339,1,13,220,339,1,14,220,353,221,352,222,351,223,350,224,349,225,349,224,349,224,349,224,349,224,340,3,6,224,340,3,5,225,341,3,3,226,341,3,3,226,346,227,344,229,325,1,17,230,237,3,83,10,10,230,234,8,80,17,2,1,1,230,232,13,28,1,47,252,230,17,24,5,45,252,228,23,16,11,42,253,227,34,1,20,38,253,226,58,36,253,225,61,33,254,224,64,31,254,223,70,25,255,222,72,23,256,221,75,20,257,218,85,12,258,217,356,217,356,215,358,213,360,212,361,211,362,209,364,207,366,204,369,204,369,204,369,204,369,204,369,202,371,202,371,202,371,202,371,202,371,201,372,202,371,201,372,200,373,199,374,199,374,197,376,196,377,194,379,194,379,193,380,193,380,192,381,190,383,183,1,1,1,3,384,183,4,1,385,186,1,1,385,184,2,1,386,184,2,1,386,183,390,183,390,182,391,181,392,179,394,179,394,179,394,179,394,179,394,179,394,179,394,179,394,181,392,180,393,179,394,179,389,4,1,179,388,184,388,184,388,185,387,184,389,185,387,187,385,189,382,192,383,142,1,4,1,43,382,141,2,3,3,42,383,145,2,1,2,41,382,145,1,2,1,42,382,191,382,191,381,192,381,151,2,39,380,2,5,145,3,39,377,4,7,185,376,4,8,185,375,5,11,140,1,42,374,4,12,131,3,6,1,42,373,5,12,131,2,7,1,43,371,6,12,127,1,56,369,5,1,3,11,125,3,56,368,9,12,125,3,56,367,7,1,2,12,125,2,57,367,7,1,2,12,184,366,11,12,184,365,11,13,183,363,14,13,183,359,18,13,183,359,18,13,183,356,1,2,18,13,182,356,21,14,181,357,3,3,15,14,181,356,3,4,14,15,181,356,4,1,15,16,181,356,4,1,15,16,183,354,21,15,183,354,21,15,183,353,22,15,182,354,22,15,181,355,23,14,180,356,23,14,177,1,1,356,24,14,177,358,24,14,178,357,17,4,2,15,178,356,18,3,3,15,178,356,19,1,3,16,178,355,24,16,178,355,23,17,178,354,23,18,179,351,25,18,179,350,26,18,181,345,27,20,182,343,27,21,182,343,26,22,182,342,26,23,183,341,26,23,183,341,25,24,184,340,25,24,184,340,25,24,185,339,24,25,185,339,24,25,185,339,23,26,187,337,23,26,188,336,22,27,189,335,22,27,191,333,20,29,191,333,19,30,191,333,15,34,191,333,14,35,192,331,15,35,192,331,13,37,193,329,14,37,193,329,13,38,194,328,13,38,194,328,13,38,194,327,14,38,196,323,16,38,198,320,16,39,200,315,20,38,200,314,21,38,201,313,21,38,201,312,22,38,202,311,22,38,202,311,22,38,203,310,21,39,204,309,20,40,185,4,21,304,19,40,171,2,12,4,5,4,15,300,19,41,171,2,7,2,4,3,7,3,15,298,20,41,176,2,1,4,13,3,17,295,20,42,176,1,2,4,14,2,18,293,20,43,181,3,13,2,20,291,18,45,172,1,25,3,19,289,16,48,172,2,25,2,20,288,15,49,172,2,48,286,15,50,223,284,16,50,224,283,16,50,225,281,17,50,225,281,16,51,225,280,14,54,224,280,15,1,1,52,223,281,16,53,223,280,17,53,223,280,15,55,223,280,15,55,224,279,14,56,224,181,5,92,14,57,224,180,7,90,14,58,225,176,11,89,13,59,226,171,16,87,14,59,227,159,28,86,2,3,8,60,227,159,28,85,2,4,7,61,227,158,29,84,1,7,5,62,227,158,28,83,2,8,1,2,1,63,229,156,28,83,2,8,1,66,230,154,29,82,2,76,231,148,34,82,2,76,232,132,5,7,37,82,1,11,1,65,178,2,54,126,54,80,1,12,1,65,177,3,58,120,56,79,1,79,176,2,63,114,1,1,58,78,1,79,242,110,2,3,59,31,1,125,243,108,3,3,60,30,3,123,244,107,68,16,2,1,5,3,27,100,244,108,70,12,40,99,245,108,71,10,42,97,246,108,123,96,246,109,124,94,247,11,1,5,1,3,8,80,1,2,120,94,247,9,22,79,124,92,248,6,25,78,127,89,248,5,29,76,130,3,5,77,249,4,33,71,142,74,250,2,35,70,145,71,248,5,36,67,147,70,247,7,37,63,150,69,246,12,38,58,151,68,245,25,2,2,30,50,24,2,126,67,245,30,34,10,2,34,22,2,127,67,245,30,40,2,7,32,151,66,235,2,7,31,51,3,2,5,1,20,150,66,229,48,65,16,4,2,143,66,229,53,62,8,3,2,87,1,63,65,230,52,64,6,26,5,53,12,60,65,230,52,93,1,1,7,52,15,57,65,230,53,89,12,52,5,1,12,54,65,230,53,86,15,61,1,1,7,55,64,230,54,82,18,69,1,55,64,230,56,79,18,49,2,75,64,230,58,7,2,69,18,45,1,2,2,25,1,50,63,227,61,7,1,70,18,41,1,2,2,2,2,24,2,50,63,227,60,7,3,73,2,5,8,1,2,36,3,1,6,25,1,51,62,226,60,9,2,83,9,34,11,77,62,226,59,55,4,39,7,34,10,7,2,5,1,14,1,48,61,226,59,19,4,31,5,43,4,33,9,30,2,27,5,15,61,226,59,16,7,32,8,39,5,26,2,2,11,10,1,3,2,4,2,8,3,26,6,14,61,126,1,99,60,16,7,31,8,39,5,25,3,1,11,1,3,6,1,3,1,1,1,1,2,2,1,8,3,26,8,13,60,228,59,16,4,5,2,26,8,40,4,25,2,2,15,5,2,3,4,1,1,6,1,5,3,26,8,12,60,228,60,17,2,4,3,26,8,41,5,22,3,3,13,6,2,5,2,8,2,1,3,8,5,18,7,11,60,229,60,22,2,27,8,40,8,20,3,3,12,4,2,1,1,3,1,1,2,9,3,1,5,5,6,18,8,10,59,229,61,50,9,39,8,22,1,1,11,1,8,6,3,11,21,17,5,12,58,124,2,104,60,50,9,39,8,21,2,1,9,1,10,4,2,6,1,8,20,20,3,11,58,122,4,104,62,48,8,39,9,21,29,6,2,5,22,21,3,10,58,122,1,107,62,47,10,38,8,23,25,12,3,1,23,11,3,8,2,9,58,230,63,45,11,37,6,25,24,15,26,9,7,7,1,9,58,231,66,41,11,33,11,20,28,10,2,7,39,16,58,231,70,38,1,2,6,33,12,8,3,8,2,1,22,14,51,12,59,231,71,41,5,30,1,2,13,7,3,7,25,6,2,7,2,1,49,11,59,230,74,41,2,28,1,2,16,3,8,8,22,1,2,4,1,8,2,1,50,10,59,230,76,37,3,29,29,7,24,3,1,15,2,1,48,9,59,106,2,5,2,115,78,34,4,28,29,6,25,23,48,10,58,105,2,1,2,2,2,116,78,34,5,20,34,9,23,18,5,1,49,8,59,103,2,2,1,122,77,34,6,18,33,11,23,19,5,1,55,2,59,230,78,33,6,17,32,13,22,4,2,15,3,1,58,1,58,230,77,34,7,15,27,20,21,4,2,1,2,12,3,1,58,2,57,230,77,34,7,13,27,22,21,1,7,7,2,5,62,1,57,229,77,35,7,11,31,20,32,4,3,4,120,229,78,36,4,10,26,2,5,20,30,10,1,2,120,228,80,15,1,1,1,19,2,4,2,3,24,30,28,12,2,1,120,227,82,11,9,16,2,5,1,1,24,33,30,1,3,3,2,3,120,227,43,6,35,2,17,23,24,32,33,1,2,4,1,4,119,229,26,22,54,22,23,31,39,6,2,1,118,87,2,144,17,27,55,20,23,31,167,87,1,146,6,37,58,17,23,28,57,3,110,278,60,14,23,17,3,2,64,7,105,278,61,12,23,18,70,8,103,278,62,8,25,18,73,6,103,278,63,4,25,18,2,1,75,6,101,278,90,19,84,1,101,278,88,16,191,9,4,17,26,27,3,124,21,352,4,16,27,25,3,126,20,352,7,13,28,23,4,127,20,353,5,13,29,23,2,131,19,76,1,265,2,9,6,10,30,9,1,1,2,144,19,74,2,261,7,8,5,10,31,1,4,1,6,145,22,1,2,65,2,265,4,6,2,15,44,148,22,65,2,265,5,5,3,5,2,7,33,2,11,147,20,65,4,263,6,5,5,3,4,2,50,147,18,333,7,6,4,3,56,147,17,332,8,7,3,3,57,148,16,331,9,6,3,4,57,149,16,329,10,5,4,3,58,149,16,328,10,5,4,3,59,149,15,328,11,4,4,2,61,148,16,327,12,4,68,147,16,326,13,3,70,145,17,325,15,1,72,144,17,324,15,2,75,140,18,323,15,2,76,141,17,322,16,2,76,141,15,323,16,2,77,140,14,6,4,314,17,1,78,140,15,1,8,313,17,1,78,140,7,1,7,1,9,312,96,140,7,3,5,2,9,311,96,141,5,5,1,6,9,310,96,142,3,6,1,7,9,309,96,144,1,14,10,308,96,160,9,308,97,159,10,307,97,158,12,306,97,156,14,306,97,154,17,305,97,151,20,305,98,148,22,305,99,147,22,305,99,148,22,3,2,299,99,150,25,299,100,151,23,299,101,151,22,299,101,151,24,297,101,151,24,297,101,151,24,297,102,151,24,296,102,151,24,296,103,150,13,5,6,296,103,150,11,8,5,296,104,148,10,11,3,297,104,148,9,312,104,148,5,1,3,312,105,146,6,1,3,312,105,145,5,2,4,312,106,143,5,3,3,313,106,143,1,1,3,3,1,315,107,141,6,3,1,315,108,139,6,3,2,315,109,137,6,5,1,315,110,135,7,321,111,133,8,321,112,132,8,321,112,131,8,322,112,130,7,1,1,322,112,131,5,325,113,129,3,328,114,127,2,330,114,126,2,331,115,126,1,331,115,458,115,458,115,458,115,458,115,458,115,458,115,458,116,457,116,457,116,457,117,456,117,456,117,456,117,456,117,456,117,456,118,455,119,454,119,454,119,454,119,454,119,454,119,454,118,455,118,455,118,455,118,455,118,455,116,1,1,455,116,1,1,455,116,1,1,455,116,457,116,457,116,457,116,457,116,457,116,457,116,457,115,458,116,457,116,457,117,456,112,3,2,456,112,3,2,456,112,4,1,456,110,5,2,456,109,464,108,465,107,466,104,469,104,469,101,1,2,469,101,472,101,472,101,472,101,472,101,472,101,472,93,2,2,1,2,473,93,1,2,2,1,474,93,480,92,481,92,481,92,481,91,482,91,482,90,483,89,484,88,485,89,484,88,485,87,2,1,483,85,3,1,117,1,366,81,120,2,332,1,37,80,119,5,369,77,1,1,118,7,331,1,37,31,2,40,123,6,213,1,157,27,8,38,120,8,372,27,9,36,120,8,373,27,1,1,8,36,117,7,12,2,362,20,17,36,116,7,13,2,41,1,320,19,7,1,10,35,116,6,11,2,366,18,8,3,8,34,116,7,10,3,111,1,254,15,12,2,9,33,115,7,11,2,111,2,254,11,1,1,14,3,8,33,114,6,9,1,3,2,110,2,255,11,1,2,25,32,114,4,11,2,371,8,3,1,27,32,114,1,387,6,34,31,502,5,35,31,150,1,260,1,90,3,37,30,88,1,62,1,258,3,90,3,37,30,88,1,320,3,91,4,36,29,409,1,1,2,91,4,36,28,150,2,353,5,35,27,151,2,353,5,36,26,151,1,354,6,35,26,438,1,67,6,2,4,29,26,150,2,131,2,221,6,3,4,28,26,149,3,54,2,20,1,277,7,2,3,30,24,150,2,56,3,10,1,180,1,104,8,1,3,30,24,402,1,104,12,30,24,258,1,248,6,4,2,30,24,507,6,35,25,507,7,34,25,204,7,17,1,278,8,33,25,145,3,55,9,3,2,290,10,32,24,145,3,55,9,14,1,4,1,275,10,31,23,205,11,293,11,30,15,1,5,208,10,293,10,31,15,2,3,210,6,296,11,30,15,4,1,213,2,6,1,9,2,279,11,30,15,155,3,54,2,303,12,29,14,151,2,3,1,66,2,6,1,288,5,1,4,30,13,151,3,68,4,1,6,288,2,1,1,1,5,29,13,151,6,65,9,1,1,289,2,2,4,30,13,149,3,3,2,67,8,291,1,2,3,31,13,149,3,4,1,69,5,329,13,149,1,6,1,72,3,329,11,148,4,5,1,369,1,33,12,147,5,2,2,1,1,369,2,32,12,147,4,3,2,1,1,370,2,31,12,147,4,6,1,371,1,31,11,147,5,5,2,371,2,31,9,148,3,380,2,31,9,148,2,415,8,565,8,565,7,155,2,410,6,155,2,137,1,272,6,247,1,319,5,156,2,129,4,277,5,156,1,127,2,1,3,278,5,283,4,212,1,69,4,282,4,282,1,1,2,569,1,264,2,1380,1,71,2,69,4,426,3,69,2,69,3,2,1,425,1,146,2,38,2,104,1,465,3,506,2,61,2,507,7,438,1,114,1,1,16,102,1,408,2,40,21,509,9,1,3,29,20,4,1,436,1,2,1,65,15,28,16,6,3,435,2,48,3,16,17,25,18,6,3,66,4,416,5,1,2,9,20,22,20,4,2,67,5,22,2,392,8,8,21,21,17,6,4,66,5,23,3,391,9,6,22,21,16,5,5,66,3,420,13,1,24,19,17,5,4,491,37,18,14,1,3,70,3,427,37,17,14,27,1,43,8,427,36,17,14,26,3,41,8,4,1,423,36,16,14,17,1,8,3,42,7,4,2,425,36,13,15,17,1,53,3,7,3,427,34,12,15,18,1,50,1,6,2,2,4,429,35,4,1,1,19,18,1,50,1,5,3,2,3,429,38,2,20,59,2,1,3,16,3,429,59,59,2,1,4,15,3,430,58,61,4,10,3,4,3,430,57,61,5,10,3,4,2,431,55,59,1,2,5,9,4,5,2,430,56,59,7,8,5,437,57,59,2,1,1,10,4,439,56,60,2,11,3,441,56,72,3,442,60,60,3,449,62,50,1,6,4,449,63,49,2,5,4,450,63,48,2,6,3,451,63,47,5,2,4,450,64,11,7,29,6,2,2,451,64,9,11,28,5,455,61,11,16,24,6,452,62,7,3,1,19,22,6,450,63,9,3,1,20,20,5,450,62,8,1,3,1,3,20,20,5,444,68,7,2,17,14,16,4,444,69,8,1,17,1,5,8,16,3,445,69,26,2,5,7,15,2,447,69,26,2,5,7,15,2,447,68,1,2,32,7,14,2,447,67,2,2,34,6,13,1,448,67,39,5,2,2,458,64,41,6,1,3,458,63,42,6,1,3,458,62,43,6,1,4,457,61,44,2,1,1,3,4,460,54,55,3,3,1,326,1,131,52,55,3,464,50,55,3,465,46,59,2,467,42,59,4,468,39,61,4,470,36,62,3,4,1,468,33,63,3,4,2,468,31,63,3,3,1,472,28,60,2,2,3,4,2,474,21,64,4,1,2,484,16,66,4,481,3,3,14,46,4,4,1,14,1,481,7,1,12,48,6,497,9,2,10,50,5,497,1,1,2,8,7,567,4,646,1,486,1,84,2,484,4,83,2,484,4,568,4,245,1,321,5,246,1,321,4,818,1,1097,1,5195,1,3625,2,570,2,572,1,3247,1,3614,2,4916,1,5784,1,568,2,489,2,571,1,2822,1,15384,1,572,2,12646,2,571,2,572,2,1720,1,571,2,2866,1,572,2,572,1,5155,2,4382,2,570,4,569,6,567,8,565,8,565,8,194,1,371,6,567,5,568,3,1139,2,202,1,364,2,1,5,566,6,560,3,2,5,562,4,556,2,11,3,558,1,1,3,8,1,561,4,570,3,32287,1,29207,1,6872,2,1,4,563,2,4,5,542,2,14,1,3,3,2,6,540,5,11,3,3,3,1,10,537,6,3,1,5,14,1,5,538,10,1,24,537,11,1,23,537,11,1,24,537,10,1,25,537,37,537,36,537,37,535,39,534,39,534,39,534,39,534,38,606,340,233,340,234,339,234,341,232,342,231,343,231,343,231,342,1,1,17,2,212,343,13,6,212,343,11,7,213,342,10,9,213,342,8,10,214,343,6,10,215,344,4,10,215,342,6,10,216,341,7,9,216,343,5,12,214,343,5,11,215,344,3,12,215,344,3,12,17,1,196,345,1,14,214,344,1,15,214,360,214,360,214,360,215,305,1,53,215,304,1,36,5,2,1,9,216,335,5,3,1,3,2,7,218,333,2,11,2,1,2,5,218,302,1,28,1,12,5,7,218,301,1,27,2,3,5,5,3,8,219,300,1,24,1,1,3,2,8,3,3,9,219,299,2,24,4,1,15,9,220,299,1,23,21,8,222,298,2,17,1,4,21,4,227,297,2,14,4,4,21,3,229,296,3,17,3,1,13,2,6,3,230,296,3,17,2,1,13,2,6,2,232,295,4,17,15,2,241,295,4,16,15,2,242,295,4,16,259,296,3,15,259,296,4,13,261,227,3,65,7,9,263,225,4,65,9,5,27,4,13,2,219,225,5,1,1,62,40,6,11,2,221,222,9,62,40,9,8,1,1,2,220,219,7,2,2,63,15,8,17,11,7,3,219,217,10,1,2,63,11,14,15,13,5,3,220,216,14,64,7,16,12,2,1,16,2,3,4,2,1,2,211,215,15,67,5,12,15,17,1,6,3,7,211,8,1,203,3,3,9,72,30,23,3,7,211,7,3,208,9,74,28,25,1,6,212,5,1,1,2,2,1,205,9,79,24,32,213,3,1,206,1,4,9,83,21,23,1,7,214,3,1,4,3,199,9,1,4,87,18,30,215,1,1,6,2,198,14,90,14,25,1,5,217,8,1,198,14,92,12,31,217,7,2,198,13,94,11,24,1,2,1,1,219,7,3,197,13,95,9,25,2,1,222,6,1,197,15,95,9,25,223,7,2,197,14,96,9,22,1,2,223,7,1,198,13,97,8,21,3,2,223,7,1,199,11,98,8,5,1,4,2,1,2,6,228,7,1,199,10,99,8,5,1,4,3,8,228,7,1,198,12,99,6,6,3,2,4,1,2,4,227,8,1,195,17,97,6,6,10,2,232,192,30,95,6,5,11,1,232,191,33,95,5,5,244,188,37,94,5,5,245,183,42,95,2,6,1,1,243,182,33,1,9,96,1,6,245,181,33,4,8,96,1,4,245,181,33,5,8,96,1,3,246,6,1,172,35,6,8,95,2,2,246,5,2,171,37,5,8,95,3,1,246,5,1,169,42,1,10,95,250,4,1,158,2,7,42,2,12,96,1,1,248,3,1,158,5,2,58,96,254,158,64,74,1,20,257,156,65,74,2,19,258,155,65,94,258,156,51,1,12,94,259,156,63,94,261,154,64,93,263,153,63,93,264,153,62,87,2,3,267,152,60,85,275,148,63,88,274,147,62,76,1,6,1,5,275,147,61,77,4,2,3,1,278,147,61,76,280,2,7,147,61,72,284,2,9,145,62,68,287,2,8,146,62,66,289,2,9,145,53,1,8,67,289,2,7,147,52,2,7,67,289,2,7,147,53,1,8,65,290,2,7,147,62,36,4,22,1,1,291,4,5,148,60,36,6,21,294,3,6,147,60,32,10,21,294,3,7,147,58,32,11,19,296,4,5,148,58,31,13,17,297,5,7,146,53,2,1,31,14,14,301,6,5,146,55,32,14,13,302,7,5,146,54,31,15,12,304,5,5,1,1,146,53,31,15,11,305,4,8,148,51,30,15,10,308,3,8,147,44,2,6,30,4,1,10,9,310,1,7,151,41,3,5,30,5,2,9,7,317,2,2,150,29,3,9,4,3,32,4,2,9,5,318,1,1,2,1,152,26,5,8,4,3,26,1,2,1,1,16,4,319,157,26,6,7,4,2,24,24,2,321,5,1,154,24,6,7,2,3,23,24,3,321,5,1,156,22,6,13,20,27,1,323,161,16,1,6,5,14,5,2,1,2,7,353,1,1,159,15,4,34,4,355,160,16,4,33,1,1,1,357,162,9,2,3,5,19,2,10,2,361,161,8,11,6,4,7,3,41,3,330,160,2,2,5,11,3,7,5,4,21,3,3,11,3,3,330,165,5,10,2,8,9,3,17,4,2,13,1,3,330,167,5,9,1,8,10,2,17,19,336,166,4,15,1,2,8,1,19,20,336,1,1,166,3,15,11,2,17,19,338,2,1,166,2,15,31,16,6,3,331,169,2,14,12,5,11,17,7,2,1,2,332,4,1,1,1,162,1,12,13,8,8,16,4,7,335,7,1,161,1,10,14,11,5,15,1,12,335,8,1,159,2,9,15,14,1,29,337,7,1,152,2,5,1,7,17,44,335,5,1,155,1,7,1,5,20,43,336,159,1,9,1,4,1,3,16,42,338,173,1,2,17,41,339,169,2,1,1,2,25,34,340,5,1,162,3,3,27,29,343,166,3,5,1,1,26,28,343,176,26,27,345,176,23,28,347,176,21,24,352,3,1,173,20,22,354,178,20,21,10,1,343,178,21,17,8,6,54,2,287,139,1,21,2,15,21,18,6,7,50,1,1,4,287,138,2,20,3,15,22,17,5,7,49,9,286,159,3,15,11,4,8,16,4,1,1,6,49,13,3,4,276,134,1,4,1,19,3,14,11,6,7,16,1,12,45,26,274,128,3,7,1,19,3,13,12,6,7,30,41,29,273,123,9,8,3,17,2,2,1,10,12,6,7,30,40,30,273,122,10,5,7,16,5,9,13,6,1,2,3,31,37,33,273,107,1,13,12,7,5,15,5,10,6,2,4,10,1,32,35,34,274,106,2,10,17,6,2,11,1,5,5,11,11,42,34,35,275,105,1,1,2,9,16,8,1,11,1,4,7,10,12,4,4,34,32,36,275,107,2,2,2,6,5,2,2,2,1,10,3,9,2,3,8,10,14,3,1,35,33,35,276,100,5,1,2,6,1,4,3,2,1,1,2,12,4,10,2,1,8,11,4,2,5,2,1,40,29,38,277,95,12,9,3,6,3,13,2,10,11,11,4,2,5,3,1,37,30,38,277,94,15,8,1,9,7,5,1,2,1,10,12,8,8,2,2,1,1,33,1,2,1,1,32,38,277,94,13,2,7,1,1,9,1,2,5,4,2,9,16,8,8,2,1,2,2,32,36,39,277,94,8,13,2,10,1,2,6,3,2,10,15,4,1,2,4,3,2,1,2,29,2,2,37,40,278,98,1,28,1,2,6,2,3,10,10,5,1,4,1,9,1,2,1,27,40,42,279,98,1,32,9,12,10,19,3,25,42,43,278,99,1,32,9,12,7,23,1,26,40,44,279,98,2,32,9,11,7,23,2,25,40,43,281,98,3,29,12,10,6,53,37,44,280,98,3,29,3,2,8,9,7,53,37,43,280,96,1,1,2,31,3,2,8,9,6,52,39,42,280,96,4,31,14,9,10,48,36,45,278,97,4,30,16,9,6,52,35,46,280,94,5,30,11,2,3,8,6,52,36,46,280,94,5,30,10,4,4,6,6,51,36,46,281,93,5,11,1,19,10,6,2,5,7,48,39,46,281,92,7,8,3,20,9,7,2,3,8,47,40,45,282,92,7,5,5,21,8,8,2,4,7,42,44,46,281,92,14,25,8,8,2,4,7,8,1,32,44,47,280,93,12,27,7,10,2,4,6,8,2,30,45,45,281,2,1,91,10,29,6,11,2,4,7,7,1,24,52,44,277,7,1,84,1,5,10,23,1,6,5,12,1,4,2,2,4,7,1,12,2,10,51,45,277,5,3,85,2,1,12,30,5,12,1,8,4,7,1,11,3,8,54,43,279,3,5,80,1,3,15,23,1,6,4,13,1,9,3,7,1,13,1,7,49,3,6,36,1,1,280,5,3,81,1,4,14,23,1,6,4,4,1,8,1,9,4,6,1,18,49,6,5,38,280,6,2,82,3,2,16,21,1,6,5,2,2,6,3,10,3,26,48,7,3,39,260,2,18,6,1,83,21,21,1,7,8,7,2,10,4,6,1,17,48,8,3,39,256,7,13,94,21,16,1,4,1,8,6,9,2,10,4,6,2,14,49,8,2,40,257,6,2,2,6,98,19,18,1,2,2,8,6,9,2,10,5,5,3,12,50,7,1,41,253,11,1,3,6,98,10,7,2,17,2,2,3,8,6,8,3,9,17,7,50,7,1,42,252,2,3,12,4,99,10,8,2,16,7,2,1,5,6,7,4,5,77,52,246,1,8,13,4,94,3,2,10,9,3,10,1,2,11,4,12,2,87,51,246,1,8,7,1,1,8,2,1,91,3,2,10,11,1,11,47,3,70,50,255,4,15,10,1,79,16,12,1,10,31,1,2,2,6,4,1,9,1,3,52,3,1,2,5,49,254,2,8,1,9,8,1,74,21,23,31,1,2,5,2,21,49,8,1,52,259,7,12,2,3,70,25,21,36,5,2,21,49,5,1,54,259,8,10,1,3,74,23,23,34,6,1,23,47,61,256,11,3,77,2,3,26,23,28,5,1,6,1,23,46,62,254,93,31,23,28,5,2,5,1,22,47,62,250,96,34,20,6,5,6,2,2,3,4,12,2,10,1,11,45,64,248,98,35,19,5,19,5,8,1,1,4,6,5,10,45,64,247,99,36,18,5,16,1,2,1,10,3,2,2,6,7,8,45,65,246,100,37,16,6,17,4,9,3,2,2,5,11,1,4,1,44,65,234,1,7,2,1,101,39,12,11,14,3,10,7,6,15,1,42,66,236,1,5,106,39,10,9,17,2,11,3,10,5,2,5,2,1,1,41,67,236,1,4,106,41,8,8,11,2,6,2,11,2,20,3,3,42,67,234,3,2,13,4,90,43,7,7,11,2,4,1,1,3,11,2,27,38,69,241,8,10,3,1,84,43,6,8,11,2,4,5,3,2,5,2,6,3,20,37,68,237,2,2,8,14,84,44,3,11,11,3,3,5,2,3,2,5,5,6,18,36,69,237,2,1,8,13,86,60,9,2,4,6,1,10,3,9,17,12,6,17,69,240,8,14,86,57,2,1,8,4,3,26,2,3,14,13,6,14,71,240,4,17,2,1,85,56,11,6,3,21,1,2,3,2,13,15,8,10,73,240,5,16,3,1,84,58,3,1,5,13,2,11,5,2,3,2,14,11,12,9,73,240,5,17,87,55,3,3,2,1,3,13,2,11,5,7,3,1,11,9,95,236,1,1,6,18,86,56,5,1,4,1,3,11,2,4,1,5,3,10,14,8,96,233,2,2,7,20,84,55,12,2,1,12,2,3,6,1,4,12,11,8,2,2,91,238,6,21,83,57,12,5,4,5,2,4,1,1,3,1,4,3,22,9,94,234,1,1,4,23,83,57,12,5,5,11,4,1,4,3,23,6,96,233,5,25,83,60,11,2,6,9,5,1,5,3,23,3,99,233,4,23,86,63,8,3,6,6,12,3,24,3,99,233,4,23,85,65,6,2,8,6,7,2,2,3,25,2,101,231,4,24,85,73,2,4,3,7,5,7,10,1,14,2,101,230,5,24,84,75,1,1,6,6,5,9,10,1,13,3,100,25,2,203,4,24,85,77,6,6,5,7,25,5,99,20,2,3,2,4,2,197,2,29,82,81,2,5,4,8,27,5,98,20,2,3,2,4,3,228,81,89,3,9,25,7,97,19,3,3,2,4,3,193,2,36,78,100,26,7,97,18,5,2,9,193,1,38,77,96,2,2,27,7,96,18,5,1,11,189,4,40,74,97,2,2,28,7,95,18,5,1,12,187,4,39,75,98,2,2,29,7,94,17,20,185,4,39,76,102,10,5,14,6,95,16,22,184,4,38,77,103,8,2,3,1,14,6,95,17,22,182,2,1,2,38,77,103,6,1,9,1,11,6,94,20,4,1,15,181,2,42,27,1,50,102,6,1,21,3,97,24,16,181,2,43,5,1,18,4,49,103,4,1,23,1,89,1,7,25,16,181,3,43,23,5,48,104,3,1,23,1,89,1,7,23,18,180,4,43,24,5,1,2,43,105,2,2,23,1,89,1,7,23,18,179,4,45,20,10,43,109,24,2,88,2,6,24,16,179,3,47,19,10,45,108,24,2,84,7,4,25,16,179,1,45,2,3,18,8,14,1,32,108,25,1,84,4,2,2,3,24,17,224,5,5,14,8,47,110,23,1,91,1,2,26,16,77,1,1,1,144,5,4,15,7,48,111,22,2,90,2,1,26,16,77,5,96,1,46,4,5,14,8,11,2,35,111,21,3,89,29,15,77,7,95,1,46,4,5,9,13,11,3,33,113,2,1,16,4,90,29,14,77,7,142,3,7,3,18,11,3,29,120,17,2,77,1,13,29,14,69,2,4,9,142,2,28,11,5,28,120,17,2,88,32,14,65,1,1,5,3,9,93,2,76,12,6,26,121,99,1,5,32,16,65,7,1,11,93,1,77,15,3,26,122,17,1,70,1,10,37,15,66,18,120,1,51,15,3,24,126,15,1,79,40,14,66,18,172,15,4,21,131,11,3,73,1,2,43,12,67,18,172,14,6,19,134,1,1,4,7,72,46,11,68,17,124,2,48,12,8,18,147,72,46,1,4,5,69,17,124,1,51,9,9,11,1,2,153,1,1,67,53,2,69,1,1,17,176,1,1,6,11,8,159,69,122,2,1,16,93,2,84,5,12,7,159,69,122,20,93,2,69,2,13,4,14,6,163,62,124,21,164,2,13,3,15,5,162,63,125,21,92,1,70,3,14,1,16,5,162,57,1,6,124,20,93,1,70,3,32,1,164,59,1,3,126,20,92,2,70,3,197,49,2,8,129,21,93,1,71,3,196,49,2,10,117,1,10,20,93,1,72,2,196,48,10,3,113,4,11,18,15,1,79,2,71,2,15,1,181,47,3,3,4,3,113,1,14,16,16,2,78,3,51,1,18,3,14,2,182,51,117,4,6,1,5,1,2,9,23,3,77,2,52,1,18,3,12,5,181,37,3,3,1,4,120,4,1,2,3,1,1,1,2,3,1,9,22,3,10,1,67,2,52,1,18,3,11,7,180,36,8,2,121,4,1,5,1,4,1,2,4,6,14,2,7,3,9,5,64,1,53,2,31,7,180,35,2,3,2,1,100,2,22,3,2,5,1,3,1,2,1,3,3,2,15,4,5,3,10,6,63,1,86,8,179,34,3,1,3,2,99,3,2,1,19,2,6,6,1,5,21,3,5,4,10,6,142,2,2,2,2,9,179,32,109,4,1,2,22,16,2,2,17,3,4,5,10,6,142,2,1,14,179,11,1,15,1,2,111,2,27,13,1,2,1,4,3,1,4,1,1,2,3,4,3,6,10,6,141,19,179,11,2,12,1,2,139,17,1,5,2,2,3,5,3,5,2,6,10,6,61,3,78,18,180,10,1,16,57,1,79,25,1,2,5,12,1,8,8,8,60,1,1,1,78,18,182,8,1,3,1,11,58,1,79,24,10,20,8,8,60,1,80,18,186,4,4,11,58,2,79,25,8,19,10,8,59,3,80,17,187,2,3,2,1,9,59,1,80,24,9,13,1,4,11,9,58,3,81,16,196,6,142,28,5,13,1,4,12,8,142,12,2,2,194,8,142,4,2,23,4,18,13,9,56,3,81,17,193,7,143,3,2,24,1,21,7,1,4,10,56,2,83,17,192,6,141,2,1,3,2,46,12,11,55,1,84,18,192,5,140,3,1,2,3,46,8,2,2,13,53,2,86,16,192,3,140,5,6,8,2,36,8,1,2,15,51,2,86,17,334,2,9,7,4,34,6,2,4,15,52,1,87,16,345,6,5,34,6,22,139,17,344,3,9,33,6,22,1,2,135,18,345,1,11,33,5,30,130,19,326,1,33,29,7,28,130,20,16,2,305,5,33,25,9,28,131,19,15,4,303,6,34,25,8,28,133,19,13,5,302,1,39,24,9,28,130,2,2,18,13,5,343,24,8,28,128,25,12,5,344,23,8,28,127,26,12,4,347,21,8,28,44,1,81,28,10,5,350,18,6,30,43,2,66,5,10,29,9,4,354,15,5,31,40,1,69,7,8,31,8,3,355,14,6,31,40,2,68,11,4,31,366,14,5,32,41,1,69,13,1,32,365,9,1,4,5,32,41,2,68,12,2,32,365,8,2,3,6,32,44,1,66,13,1,33,364,7,3,2,6,33,112,46,365,5,8,37,112,47,366,1,9,38,111,48,375,39,111,48,375,39,44,2,64,49,191,1,183,39,43,2,65,49,191,4,2,1,176,40,110,49,191,9,174,40,109,51,189,11,172,41,109,51,189,11,172,41,108,52,189,11,103,4,1,2,62,41,108,53,186,14,101,11,1,2,54,43,107,54,186,12,1,2,99,18,1,2,47,44,107,54,183,18,1,2,96,22,45,45,107,55,181,23,93,23,1,2,42,46,106,56,182,5,1,17,91,23,2,3,37,50,106,48,4,2,184,6,1,17,89,30,33,53,105,49,188,8,1,18,87,32,31,1,1,52,105,49,4,3,182,7,1,18,85,1,1,32,30,1,1,53,104,52,2,4,180,8,2,4,96,1,1,35,30,54,103,54,2,3,180,8,4,4,93,38,30,54,102,60,180,8,4,4,94,37,29,55,102,59,181,7,6,7,90,37,29,55,48,1,52,59,195,6,89,39,29,55,48,1,52,59,197,5,86,41,28,56,48,1,2,1,48,60,190,1,6,5,81,1,2,42,30,55,51,2,47,61,179,1,9,2,5,3,19,2,42,2,18,1,1,42,29,57,50,3,46,62,177,2,8,2,71,3,14,1,3,44,9,5,16,57,51,2,44,64,177,1,9,1,68,2,2,2,11,3,1,47,9,10,12,57,97,65,254,3,1,2,9,53,9,12,11,57,99,64,252,6,7,54,11,12,2,2,7,57,101,62,250,8,1,60,11,17,6,57,102,61,253,4,1,60,10,19,1,1,4,57,102,61,249,3,1,64,10,22,2,59,102,61,44,1,202,5,1,64,9,84,102,61,7,2,237,73,7,84,102,61,163,3,77,78,12,9,1,67,102,62,4,3,42,1,100,1,7,1,1,5,76,80,6,1,4,3,3,71,102,63,2,6,40,1,99,3,7,7,75,2,1,79,4,1,4,3,1,7,1,65,101,73,141,5,3,7,74,2,1,81,9,1,4,6,2,63,101,74,28,1,106,2,2,7,2,2,1,4,76,83,12,1,1,5,2,63,100,75,27,3,105,1,5,5,5,2,73,1,2,87,10,2,2,3,2,63,99,77,26,4,110,9,1,2,72,2,1,89,7,6,1,2,2,63,99,2,1,74,26,6,105,7,3,2,1,2,71,94,7,5,1,2,1,64,102,15,1,58,26,6,1,1,100,3,1,3,2,1,1,2,76,95,4,12,2,61,101,15,2,59,26,7,100,12,75,98,2,11,4,61,101,14,3,59,28,4,1,2,99,11,73,112,4,62,64,2,34,13,4,60,33,4,104,1,76,107,1,1,1,1,5,62,65,2,33,12,4,61,32,8,63,2,36,2,75,106,4,1,4,63,101,9,2,1,1,63,31,9,63,2,3,2,109,107,5,65,95,2,4,8,3,65,32,8,62,5,1,2,9,2,96,109,5,65,94,3,5,6,5,65,1,2,28,7,62,6,109,62,2,46,5,65,66,3,25,2,5,7,5,69,3,4,20,11,58,6,109,57,12,40,4,67,67,4,23,2,4,7,5,78,19,11,58,6,110,55,15,38,4,67,69,2,22,3,3,8,5,79,19,10,58,7,108,54,19,32,1,3,5,2,1,63,93,1,3,10,4,80,20,9,58,7,109,39,4,8,21,32,11,64,93,1,2,11,4,81,20,7,56,10,108,37,8,6,22,31,13,63,95,11,4,84,6,6,1,1,4,6,1,3,53,11,15,2,91,36,36,30,5,3,6,63,95,10,5,85,5,9,2,7,1,2,53,11,16,2,91,36,37,12,3,14,6,2,6,63,87,3,4,11,4,88,3,9,10,1,51,2,2,9,110,3,1,31,17,2,19,10,9,10,6,2,6,63,86,4,4,10,5,5,2,82,3,5,63,4,2,8,115,31,17,5,17,8,14,3,16,64,81,1,4,4,3,10,6,5,2,83,4,2,63,5,1,8,116,31,15,1,1,6,17,7,11,8,14,64,78,12,1,12,6,1,1,1,5,83,4,1,62,6,1,7,117,31,12,13,12,2,40,65,78,24,15,85,65,13,116,34,2,1,3,19,10,3,39,66,77,25,15,83,12,3,50,1,1,7,2,1,119,60,9,3,16,1,22,66,78,23,16,83,11,3,49,3,1,7,122,63,23,5,19,67,79,22,17,83,67,6,122,67,3,2,13,8,15,69,79,22,17,83,69,4,123,67,17,2,1,3,17,69,78,22,18,83,71,2,123,66,40,70,77,22,19,80,67,3,129,67,1,1,36,64,1,6,75,23,19,80,64,2,1,5,48,5,6,4,64,70,36,64,2,5,70,27,19,80,68,6,47,19,60,69,36,64,3,2,1,2,70,27,19,82,55,4,4,9,47,24,54,70,36,64,77,28,18,84,53,8,1,9,47,24,54,70,36,63,78,27,19,84,51,10,1,10,6,1,9,1,30,25,52,70,36,63,79,26,18,87,49,21,6,2,8,1,33,23,51,71,5,2,2,1,27,61,79,25,18,89,47,22,61,14,49,70,5,3,1,3,26,63,77,26,17,89,16,4,27,21,5,1,58,15,46,69,7,8,2,3,2,1,16,65,75,26,17,89,15,6,4,1,20,25,63,13,46,17,1,50,5,2,3,4,3,10,13,65,74,26,17,90,4,2,7,13,20,25,66,11,45,17,1,50,5,8,3,12,8,70,73,26,17,95,8,13,20,26,1,4,61,13,43,16,2,48,4,8,5,14,5,71,72,27,16,96,6,15,20,27,1,6,60,13,41,16,2,47,4,9,5,88,73,28,10,3,2,96,7,15,20,34,61,12,41,16,2,46,5,9,6,17,1,71,69,28,12,4,1,96,7,14,22,34,63,10,40,16,2,45,5,10,6,90,66,29,13,100,6,15,20,2,1,36,63,12,36,16,2,44,5,11,7,88,66,29,15,99,5,17,7,2,10,3,1,37,12,2,47,13,34,16,4,42,6,14,5,87,67,28,15,98,1,1,2,21,5,5,7,3,2,38,10,2,50,10,34,16,7,39,6,15,4,88,66,27,16,126,2,8,4,2,3,39,1,1,59,10,35,14,9,37,7,108,65,27,18,134,2,2,2,1,2,41,60,9,35,14,9,36,8,108,1,1,63,26,18,136,1,49,60,8,26,1,8,14,7,2,1,35,7,111,62,26,19,144,1,42,59,8,25,2,8,14,7,2,3,34,6,111,62,25,20,144,2,41,1,1,58,7,25,2,9,12,13,34,3,2,1,111,61,25,21,143,3,41,1,2,25,1,31,7,24,4,9,11,6,3,4,34,2,115,59,26,23,143,3,40,4,3,20,3,30,7,13,3,7,6,9,8,8,4,3,151,58,25,25,3,2,140,2,38,5,2,21,4,29,6,13,5,6,7,11,2,11,4,3,33,1,117,57,25,26,3,2,140,2,37,19,3,7,5,28,6,13,5,6,9,22,5,2,151,57,23,28,3,2,191,7,1,10,5,27,4,15,6,5,10,4,1,6,5,5,5,2,151,56,22,32,2,3,190,10,2,4,7,26,3,16,6,6,9,5,12,4,4,3,151,56,19,35,1,5,189,11,1,3,9,25,2,29,2,4,3,5,12,3,5,3,151,55,17,44,189,2,1,7,1,4,9,62,4,3,13,3,6,1,152,55,15,45,190,1,3,6,1,4,10,61,5,2,175,54,14,47,190,2,2,1,2,3,2,3,11,21,2,30,1,6,7,1,174,54,12,48,191,4,4,2,2,4,11,20,3,18,13,5,182,53,9,53,190,3,5,2,3,4,13,17,3,12,5,1,15,2,183,53,6,58,188,2,5,4,5,1,14,15,4,13,205,53,5,58,187,2,6,1,9,2,14,14,3,15,204,53,1,63,186,2,17,2,14,12,4,16,203,118,184,2,18,2,12,1,1,11,5,11,3,1,204,51,2,66,196,2,5,1,14,11,6,10,209,51,2,66,195,2,6,1,14,9,8,3,216,51,2,65,194,1,9,2,14,8,8,3,216,50,5,66,180,1,20,2,15,6,9,3,216,49,3,1,2,66,181,1,19,2,16,4,14,1,214,49,2,71,180,1,19,3,15,4,229,49,2,71,201,2,15,3,230,49,2,72,201,2,12,5,230,49,1,74,177,1,22,2,12,4,231,124,201,1,12,3,232,125,200,2,11,3,232,125,200,2,11,2,233,46,2,77,200,2,11,2,233,45,2,78,200,3,11,1,233,45,1,79,195,2,1,5,245,124,198,5,246,124,194,1,6,2,246,124,193,1,7,2,246,43,1,79,194,1,8,2,245,123,194,1,7,3,245,123,194,1,7,4,244,123,203,3,244,122,204,5,242,122,206,4,241,121,208,4,240,121,208,5,239,121,209,5,238,38,1,82,211,5,2,1,233,121,214,2,236,121,214,1,237,121,452,120,453,120,453,120,453,35,1,60,2,22,453,35,1,59,3,22,453,34,1,59,4,21,454,34,1,57,3,24,454,89,5,25,454,88,6,24,455,86,7,25,455,86,8,24,455,85,9,24,455,84,9,25,455,83,9,1,11,7,1,6,455,81,10,2,11,6,4,4,455,32,1,46,11,3,13,4,4,4,455,32,1,44,12,1,16,4,5,3,455,32,1,43,12,2,15,7,3,2,456,31,2,41,31,12,456,31,2,39,14,1,18,3,1,3,1,4,426,1,29,31,1,39,13,2,18,2,3,2,3,4,417,3,3,3,6,1,22,30,2,36,13,4,19,1,4,1,4,3,418,11,4,3,20,30,2,34,14,5,23,1,426,12,2,6,18,65,14,6,451,20,17,62,16,6,452,22,2,3,10,59,18,7,452,28,2,1,6,30,2,33,11,7,453,31,6,30,2,34,8,8,454,32,5,30,2,34,7,8,455,32,5,30,2,33,7,8,455,34,4,30,3,31,7,8,455,36,3,30,2,32,6,8,456,36,3,30,2,31,6,8,457,2,4,31,2,30,2,30,6,8,464,32,1,29,2,31,6,7,465,32,1,29,2,30,6,7,466,32,1,29,2,29,6,7,467,32,1,28,2,29,4,9,468,32,1,28,2,28,4,10,468,32,1,28,1,25,7,9,455,6,10,31,1,50,1,1,8,10,454,8,11,29,1,29,1,18,12,9,454,9,12,27,2,29,2,16,11,10,453,12,11,27,2,24,2,2,3,15,3,1,7,11,450,15,11,27,2,24,2,2,2,16,1,5,4,12,450,15,7,1,1,28,3,28,2,21,4,12,450,15,6,32,3,28,1,2,1,19,4,12,448,4,2,10,4,35,3,27,2,1,1,19,4,13,447,2,6,9,4,35,3,27,4,18,4,14,455,9,4,35,3,24,1,1,2,1,2,17,3,15,456,7,5,33,1,1,4,24,1,3,3,17,2,16,461,3,3,32,8,24,1,1,5,34,463,1,3,30,11,23,10,32,468,28,12,23,11,7,6,17,469,27,13,23,24,17,469,26,14,23,23,18,469,25,15,23,23,2,1,14,470,25,15,24,20,1,3,15,470,25,15,24,18,20,471,24,16,25,16,20,472,24,16,25,15,21,473,22,17,24,16,20,473,22,18,24,15,21,473,22,18,24,14,22,473,23,17,23,14,22,474,23,17,23,14,22,475,22,17,22,14,23,475,21,18,21,14,23,476,21,18,21,13,24,476,22,17,23,12,23,477,21,17,26,11,21,477,22,16,28,9,20,478,21,17,29,7,21,478,20,18,29,6,22,478,20,18,29,5,22,480,20,17,31,3,22,480,20,17,31,3,22,479,20,18,25,9,21,480,20,18,25,8,22,480,20,18,21,2,2,7,23,481,19,18,20,4,2,4,25,481,18,19,19,5,1,3,3,2,22,481,18,19,18,2,1,2,2,3,26,483,15,21,15,9,1,2,27,425,11,9,1,37,14,22,13,11,29,425,16,1,3,1,3,36,12,23,11,12,30,425,25,36,11,23,10,12,31,425,27,34,11,23,9,13,30,425,31,32,9,24,8,14,30,422,34,35,3,27,7,14,31,422,34,65,6,14,32,423,34,64,5,14,33,424,33,64,5,13,34,425,17,1,14,64,5,12,35,426,15,3,13,64,4,13,35,428,6,3,6,1,14,63,4,10,38,429,4,7,19,62,3,10,39,441,1,3,16,60,2,11,40,429,1,10,1,4,16,59,2,10,41,445,17,58,2,9,46,2,1,437,18,58,2,9,50,436,18,58,1,9,51,437,18,67,50,438,18,66,51,439,18,64,52,439,18,64,52,440,17,63,53,441,17,61,53,442,17,61,53,442,17,61,3,1,50,441,17,61,1,3,50,441,18,60,1,2,51,441,18,59,2,1,51,441,19,59,54,440,21,57,55,441,20,57,54,443,20,56,52,447,18,56,52,448,17,56,3,2,46,450,17,55,3,2,45,446,1,4,17,55,2,3,45,444,5,3,15,56,2,3,45,445,5,2,15,56,1,3,46,445,6,2,14,3,1,55,47,446,6,1,14,2,4,52,48,446,28,50,49,447,6,2,20,49,49,446,7,3,20,47,50,446,6,5,21,45,50,446,6,6,21,44,51,446,1,1,2,8,23,40,52,459,23,39,52,460,23,37,53,460,24,36,52,459,27,33,53,461,27,32,53,464,25,31,48,470,24,31,1,2,42,472,26,34,24,2,13,43,1,429,3,1,23,34,7,2,28,22,2,1,1,1,2,13,7,426,3,2,21,36,6,1,27,23,9,12,6,428,24,32,18336,1,572,1,572,2,571,2,395,1,175,2,387,2,4,3,175,2,386,4,1,5,175,2,386,10,175,2,386,2,1,6,176,2,386,9,176,2,387,1,1,2,1,2,177,2,392,2,177,3,570,1,572,1,572,1,1718,1,572,1,572,1,480,1,91,1,479,2,91,1,3226,3,570,2,786,2,571,3,571,3,571,2,2865,1,573,1,572,2,571,3,569,5,568,6,567,7,566,7,567,7,566,7,566,8,564,9,563,12,560,13,554,1,4,15,553,2,2,17,552,2,1,19,554,19,554,20,554,19,555,19,555,18,556,17,557,17,557,16,558,2,1,11,560,1,2,10,563,10,494,2,69,3,2,2,495,2,70,2,19138,2,29,1,541,2,4,3,22,1,541,1,5,3,571,2,582,3,553,6,2,2,8,1,552,9,2,1,3,1,9,3,1,8,15,1,519,13,3,31,2,2,1,2,517,51,2,3,516,56,515,61,510,64,492,8,8,66,490,10,6,69,488,11,4,72,486,89,484,90,483,92,480,95,477,96,477,96,478,95,483,91,21,2,451,99,21,6,446,100,20,11,440,103,18,18,430,108,17,19,428,110,16,21,15,2,1,5,398,1,4,111,15,26,9,11,392,120,15,27,2,2,1,1,2,12,387,1,2,121,14,35,2,12,384,130,10,50,383,131,10,35,1,14,382,132,8,51,382,132,8,51,382,132,1,1,6,51,382,131,1,2,8,50,371,4,5,134,5,1,3,50,370,7,3,133,6,2,2,49,370,144,5,53,369,146,5,52,368,148,5,55,1,1,363,148,5,57,363,148,5,56,364,148,5,53,364,151,6,52,364,151,6,52,363,154,4,53,1,3,358,153,4,58,357,154,1,2,1,58,356,156,3,57,357,157,2,58,356,157,1,60,354,158,1,59,355,158,1,60,353,158,2,60,353,221,352,221,351,222,351,222,350,223,349,224,349,225,253,1,94,225,253,2,92,226,346,227,347,226,346,227,346,226,351,221,352,220,351,222,350,222,351,222,191,6,155,224,186,8,155,224,185,10,154,226,182,11,156,225,2,2,1,2,172,13,156,233,171,13,155,234,171,13,155,234,171,12,155,234,172,13,154,231,175,13,2,1,1,2,147,231,176,13,2,4,21,3,122,231,177,13,2,3,23,2,122,230,178,14,2,2,146,231,178,14,2,1,148,231,177,14,151,231,177,14,151,231,177,14,151,231,177,14,151,232,176,14,147,2,1,233,176,14,147,235,177,13,149,234,177,12,150,234,177,11,152,233,4,1,172,9,154,233,2,4,171,9,155,232,2,3,172,4,3,1,156,232,341,232,340,234,227,1,111,235,1,2,222,2,110,240,334,238,335,237,336,240,312,1,20,241,311,1,20,241,333,239,314,1,20,236,338,235,338,236,3,1,334,235,1,4,334,238,313,2,19,1,2,235,315,1,18,240,333,240,4,1,329,244,329,241,1,2,328,242,331,242,331,243,330,243,330,243,330,31,1,213,328,31,1,213,328,28,4,211,331,27,6,208,333,19,2,3,11,204,335,16,22,200,335,16,22,201,334,15,24,201,334,11,30,10,3,187,332,12,30,7,7,1,2,183,330,12,2,1,30,4,11,182,333,3,2,1,5,2,22,4,2,5,15,178,370,4,1,4,18,177,369,3,2,2,1,2,18,176,369,3,2,1,2,1,20,174,371,1,28,173,401,1,1,170,402,171,403,170,404,169,404,168,1,2,403,167,2,1,406,164,409,167,406,166,408,162,412,161,412,160,4,3,407,159,5,2,408,157,416,156,418,154,419,156,418,155,418,154,409,2,9,154,1,2,405,3,8,160,402,4,8,154,1,4,404,5,6,151,4,2,406,5,3,1,2,151,411,5,1,4,1,150,412,11,1,149,413,11,1,148,2,1,407,3,1,164,406,2,2,164,395,1,13,161,398,2,12,161,398,3,9,158,2,3,399,2,9,158,389,4,15,2,5,159,387,6,20,162,384,8,19,162,385,8,9,2,2,168,385,7,8,170,392,3,9,161,4,3,405,160,5,4,404,159,3,2,2,3,396,2,6,109,1,49,407,2,6,108,1,38,2,6,1,2,392,4,3,1,15,107,2,38,2,6,393,7,1,5,9,1,2,106,3,38,3,5,392,8,1,6,7,110,2,30,1,3,1,2,6,1,396,14,7,108,1,2,1,30,18,2,390,18,3,106,3,2,1,30,410,126,4,2,1,28,412,109,3,10,9,1,2,27,7,1,405,110,3,7,10,1,2,26,8,3,406,92,1,14,5,5,12,27,9,4,404,93,2,12,20,1,1,26,10,5,403,93,3,10,21,27,11,1,407,2,1,90,6,5,22,27,418,2,1,1,1,90,33,25,419,97,35,21,420,1,1,97,20,1,12,19,423,3,1,93,18,6,12,13,425,2,1,1,3,89,17,11,13,8,428,6,2,89,14,14,447,102,8,17,447,101,8,18,446,100,10,18,446,97,14,16,445,98,5,3,10,13,442,2,1,96,5,4,12,12,441,2,1,96,4,6,12,11,444,95,4,8,11,12,443,95,4,4,1,3,12,10,444,95,4,2,3,4,13,8,444,90,9,1,6,2,14,7,446,88,10,2,22,3,448,88,10,2,473,88,10,2,473,88,9,2,474,88,6,2,1,2,474,89,4,7,473,89,4,4,1,1,475,88,5,5,476,87,5,6,475,85,9,6,473,81,15,4,473,81,18,1,474,79,2,4,490,77,1,6,489,76,1,7,488,1,1,75,1,6,3,4,482,3,1,79,3,6,482,2,3,76,2,8,483,1,3,75,1,10,488,84,489,82,490,82,492,1,2,78,7,3,487,76,5,7,487,74,3,17,469,1,3,3,4,96,465,9,1,1,3,94,465,13,2,94,2,1,461,7,2,4,3,97,461,1,5,6,3,99,465,6,1,1,2,99,466,6,5,6,1,4,1,84,468,1,1,2,3,1,3,4,2,3,7,79,470,1,3,2,2,4,2,3,8,79,473,2,2,3,3,3,9,7,1,70,476,4,2,4,13,2,5,69,475,1,4,3,19,68,1,3,499,74,500,73,497,76,128,1,368,77,495,79,492,81,491,49,1,4,1,27,492,49,1,4,12,16,496,32,2,9,2,5,12,15,485,2,2,37,5,5,4,5,8,2,4,14,485,1,3,35,7,5,5,4,4,7,4,14,487,36,8,3,7,2,4,10,2,16,485,3,4,5,7,13,2,1,9,2,14,10,2,16,508,2,1,4,30,11,1,15,1,1,502,1,4,2,1,4,35,7,1,14,1,2,491,6,2,2,5,2,3,2,27,3,1,1,1,9,1,15,486,14,1,2,5,2,31,16,1,14,487,15,40,17,1,14,487,14,41,16,1,14,1,2,486,2,1,7,43,16,1,14,493,2,2,2,48,3,1,24,550,7,1,16,537,7,5,7,1,16,537,8,5,6,1,16,538,7,4,1,2,4,1,14,5,1,545,7,1,14,5,2,544,7,1,14,544,1,6,7,1,15,542,3,5,7,2,2,2,10,542,3,4,8,6,7,1,4,541,2,4,2,1,5,6,7,554,6,7,6,554,6,7,8,553,5,8,5,569,5,568,5,568,6,566,9,561,3,1,9,2,1,2,1,554,16,2,2,1,4,549,15,2,2,1,6,548,24,550,5,1,14,554,4,2,1,1,11,61,1,493,2,5,13,14,2,43,1,498,1,2,12,14,2,42,2,498,1,5,11,8,1,1,4,545,1,5,12,2,1,1,2,1,4,544,2,4,24,3,4,86,2,449,1,5,21,2,2,1,4,86,2,457,2,1,2,2,16,1,3,87,3,455,7,3,14,2,2,88,2,455,4,1,3,4,1,5,5,3,1,89,2,457,3,1,3,3,2,102,2,462,1,108,3,570,2,571,2,494,1,76,2,470,2,23,1,75,1,473,2,1,8,10,1,544,2,3,4,2,7,9,2,28056,1,572,3,569,1,17,2,553,2,5,2,7,3,552,3,2,4,1,7,554,1,1,3,1,13,553,18,555,17,553,2,1,16,553,3,2,15,552,2,1,17,36,2,1,2,512,20,35,10,507,20,37,10,505,9,1,11,32,15,508,6,1,11,32,8,1,5,507,8,1,10,33,2,1,10,508,4,2,2,1,11,32,2,1,7,507,13,2,8,37,3,509,6,1,5,3,9,38,2,510,12,1,11,548,13,1,11,547,15,1,10,548,8,3,4,1,9,549,17,2,2,3,2,545,23,2,3,544,3,1,5,1,19,543,2,3,25,543,1,3,26,547,26,547,26,544,2,1,27,543,3,3,24,543,30,543,2,1,1,1,26,543,1,4,25,542,3,4,26,540,35,541,37,536,38,535,39,532,1,1,40,531,3,1,38,532,2,2,38,531,44,530,45,531,46,524,52,521,54,521,52,521,54,518,55,519,55,518,55,518,55,519,52,521,50,524,10,1,38,524,5,1,43,527,45,528,2,1,42,533,41,533,40,534,40,534,41,525,1,3,45,523,3,1,48,521,57,1,3,513,61,515,60,515,60,513,60,514,60,515,59,516,2,1,2,2,50,516,6,1,52,517,3,2,53,514,63,506,1,3,69,504,6,2,54,3,5,504,6,2,54,2,5,507,3,2,62,507,1,4,56,1,4,507,3,3,55,512,3,4,52,521,52,510,1,10,52,513,4,5,51,10,4,499,6,3,51,7,10,496,6,3,51,5,12,497,5,3,50,5,13,497,4,5,49,3,15,497,5,4,49,1,17,497,5,4,67,497,5,4,68,496,5,4,69,496,6,2,69,15,11,470,1,1,75,7,22,468,77,2,26,468,74,2,30,466,75,1,32,465,109,464,110,463,111,463,110,463,110,464,109,464,109,464,107,467,105,469,103,471,102,471,102,14,5,452,103,11,10,448,104,10,12,447,104,5,18,445,104,5,19,445,103,5,22,443,102,4,27,440,101,4,29,439,99,5,30,439,98,3,34,437,98,2,36,437,98,2,37,436,98,1,38,436,140,433,2,1,140,433,136,2,4,432,135,4,3,431,135,4,4,431,137,3,3,430,137,4,3,429,138,3,4,429,137,3,4,430,144,429,144,429,145,429,144,430,144,429,145,429,146,427,149,424,149,425,149,424,149,424,149,425,148,425,149,425,149,424,149,423,149,425,148,426,146,379,2,46,146,427,146,427,146,427,146,427,147,426,147,426,146,426,148,425,148,425,149,424,148,1,1,423,152,421,152,420,155,418,158,10,2,404,159,7,3,404,170,405,168,405,168,405,168,405,168,405,168,404,169,404,169,404,169,404,169,42,1,362,168,405,168,406,167,406,167,406,167,406,167,407,166,407,166,407,166,163,1,243,166,163,1,244,165,408,165,408,165,409,164,409,164,409,164,409,164,409,164,409,164,409,164,409,164,410,163,411,162,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,410,163,411,162,411,162,412,161,412,161,412,161,412,161,412,161,412,161,413,160,413,160,413,160,413,160,413,160,412,161,412,161,412,161,412,161,412,161,413,160,413,160,413,160,413,160,412,161,412,161,412,161,411,162,411,162,411,162,411,162,411,162,411,162,410,163,409,164,408,165,406,167,405,168,405,168,404,169,404,169,402,171,400,173,399,174,398,175,396,177,394,179,393,180,391,182,389,184,388,185,386,187,385,188,383,190,381,192,380,193,380,193,379,194,378,195,377,196,376,197,375,198,374,199,374,199,373,200,373,200,373,200,374,199,374,199,373,200,373,200,372,201,372,201,371,202,370,203,370,203,369,204,368,205,368,205,368,205,367,206,366,207,365,208,365,208,365,208,364,209,364,209,363,210,362,211,362,211,361,212,361,212,361,212,360,213,360,213,359,214,359,214,359,214,358,215,358,215,358,215,357,216,356,217,356,217,355,218,354,219,353,220,353,220,352,221,352,221,351,222,350,223,350,223,349,224,347,226,345,228,343,230,342,231,342,231,344,229,344,229,343,230,343,230,342,231,342,231,342,231,341,232,341,232,341,232,342,231,343,230,344,229,345,228,346,227,347,226,349,224,350,223,348,225,348,225,347,226,346,227,344,195,1,6,1,26,344,201,3,25,345,226,1,1,345,181,2,21,1,21,347,204,1,19,349,204,2,16,351,205,1,14,291,1,60,207,1,11,354,190,2,15,1,10,288,4,8,2,53,190,2,15,2,7,290,5,1,2,4,3,54,188,2,15,300,3,2,3,61,187,2,16,297,5,2,2,62,186,3,16,296,5,1,2,64,186,1,17,299,2,2,2,65,189,1,3,1,3,304,3,70,196,305,1,71,187,1,8,378,194,379,191,381,192,381,192,383,188,387,187,389,185,389,185,387,186,387,186,388,185,390,183,390,183,390,182,391,181,394,179,396,174,1,1,398,173,401,172,402,171,402,170,404,169,404,169,404,168,404,169,404,169,404,169,405,168,405,168,405,168,405,167,406,167,406,166,406,167,406,165,408,164,410,162,410,162,411,161,412,159,414,158,415,158,414,157,416,153,419,132,8,11,397,1,4,4,15,133,415,2,4,6,12,132,417,2,1,9,11,132,420,10,11,131,420,10,11,131,413,2,6,9,12,127,416,18,13,127,412,23,6,2,3,127,411,26,4,2,1,10,1,118,411,26,7,9,1,118,413,26,4,10,3,116,413,14,5,20,7,113,413,11,2,1,7,18,9,111,412,13,13,14,11,109,407,1,3,15,15,10,13,108,407,3,1,14,18,5,19,27,3,64,1,8,408,5,1,12,46,25,3,64,4,4,408,19,45,25,5,64,415,17,48,23,6,65,414,16,49,23,5,66,414,16,48,25,4,67,414,14,50,24,3,68,412,16,50,25,1,68,413,15,52,91,416,13,54,89,416,14,55,59,7,15,2,1,419,15,56,3,1,17,1,21,5,9,10,13,4,5,411,18,60,38,10,4,11,11,6,5,409,19,60,16,4,18,25,11,7,4,408,20,66,9,7,16,18,2,8,1,1,10,3,3,409,20,68,7,10,12,19,1,5,4,7,6,1,4,408,21,69,8,9,9,27,5,13,5,405,23,71,8,6,4,36,1,17,2,404,25,71,7,6,4,459,26,72,7,5,3,459,27,72,7,5,3,5,2,50,2,400,27,74,4,13,3,2,2,441,7,1,26,86,1,4,1,4,1,440,36,85,2,446,40,531,42,138,2,388,45,138,2,382,52,519,54,518,56,515,58,514,59,513,60,512,61,139,2,370,62,139,2,9,1,359,63,149,2,358,63,509,61,491,2,18,62,144,2,343,7,13,35,2,25,146,2,338,15,8,34,18,9,150,1,337,19,2,38,512,62,12,1,496,65,12,1,2,1,157,3,330,68,172,2,328,71,171,3,325,74,497,76,495,78,1,1,168,2,320,81,1,2,167,2,319,82,2,1,167,2,317,84,488,87,485,88,166,2,1,1,314,88,65,6,96,2,311,51,4,40,62,12,91,4,307,53,7,11,2,24,60,13,30,1,62,3,304,54,14,8,1,24,58,14,15,1,13,3,57,1,309,54,23,25,59,10,16,3,12,5,56,1,308,51,28,24,83,14,2,6,365,50,30,24,82,23,52,2,3,2,303,51,33,22,83,5,1,2,1,18,20,1,25,2,4,2,302,51,34,22,38,2,52,1,2,17,6,2,8,8,7,2,11,1,307,53,35,21,90,3,1,27,7,10,324,54,36,21,90,2,1,29,6,13,21,2,258,2,37,55,37,20,93,29,6,11,23,1,259,1,37,55,38,20,93,28,12,6,4,2,9,2,303,56,38,20,2,1,59,2,29,26,26,1,8,2,302,56,39,21,1,2,58,9,18,27,342,55,40,25,57,18,9,23,2,2,341,55,41,23,61,20,6,7,1,14,345,54,43,23,61,20,7,2,6,9,1,1,345,55,43,23,60,21,372,53,45,22,54,24,377,51,48,19,52,24,377,53,54,13,52,19,383,52,58,1,5,2,24,4,25,19,12,2,370,51,81,1,8,4,24,17,15,4,368,50,80,6,5,4,17,19,20,5,367,49,82,5,6,2,15,21,25,1,366,50,84,7,12,1,1,24,386,2,5,50,85,8,7,29,28,1,365,50,85,10,5,27,395,51,87,9,6,21,1,2,36,1,2,2,355,51,88,29,4,3,25,1,14,2,356,52,90,26,33,2,370,52,93,20,37,1,4,4,361,52,98,8,1,3,41,2,4,2,361,53,149,3,368,54,144,1,373,55,142,2,373,56,142,2,350,2,20,57,126,2,9,2,3,1,350,5,17,58,126,2,9,1,4,1,350,5,16,59,125,3,365,5,16,59,125,3,364,6,15,61,101,1,21,3,14,1,5,1,343,6,15,62,102,1,1,1,16,5,14,1,5,1,342,7,14,63,121,5,13,1,348,7,14,64,107,1,14,4,12,2,347,7,14,66,102,6,13,3,9,2,2,1,347,9,11,68,102,7,12,2,2,3,6,1,348,6,1,1,13,70,101,6,26,1,347,6,16,70,100,8,23,3,345,8,15,71,99,9,21,3,345,10,15,71,98,11,368,11,13,72,97,12,367,12,11,74,97,12,16,3,348,10,11,76,95,14,17,2,349,9,10,76,96,14,17,2,349,8,10,77,95,15,7,4,6,2,350,7,9,78,94,16,8,6,3,2,349,7,10,78,94,16,16,2,350,7,11,77,93,17,13,4,351,8,11,76,93,16,368,7,12,78,92,16,368,7,12,79,90,16,367,8,10,83,89,16,366,9,10,83,89,15,366,10,9,87,86,15,365,10,9,88,87,14,362,1,2,8,9,94,83,14,361,12,9,96,81,14,360,12,9,99,31,1,4,3,40,13,360,12,10,99,24,5,1,2,3,4,39,14,358,14,10,101,22,14,39,14,358,14,8,106,13,5,1,13,39,15,359,13,8,104,1,6,5,8,1,14,38,16,358,13,8,141,24,5,7,16,358,14,8,138,1,3,1,1,21,8,3,17,357,3,1,11,7,136,2,3,1,1,22,9,2,18,362,9,7,145,1,5,1,4,6,32,356,2,6,8,6,195,356,2,6,7,6,196,356,2,5,7,4,198,363,8,4,198,363,8,4,198,362,9,5,197,361,7,1,2,4,199,359,10,5,199,359,7,1,2,4,201,356,8,8,201,355,8,8,203,335,1,17,8,9,203,334,2,16,8,10,204,350,9,9,206,349,8,10,208,347,8,9,209,347,8,9,211,343,10,9,213,341,10,9,214,340,9,8,218,338,9,7,219,337,10,6,221,335,11,2,225,335,11,1,227,333,241,332,243,329,248,325,248,325,249,323,251,81,1,240,252,320,255,318,260,312,261,312,259,314,260,312,263,3,1,299,1,6,264,301,2,5,266,1,2,303,268,300,2,3,269,292,1,5,2,2,267,2,1,293,1,8,271,300,272,301,272,299,274,297,275,291,5,1,274,292,2,4,275,1,2,294,279,291,279,1,3,287,282,2,3,285,283,3,2,285,283,2,4,284,283,2,5,283,282,1,7,283,291,280,293,280,293,280,293,279,285,1,7,1,1,277,293,2,2,275,299,273,301,272,301,271,304,268,305,268,305,268,306,267,306,267,306,265,307,266,311,261,315,258,318,254,321,252,315,3,5,250,320,252,324,248,328,244,331,2,2,1,2,235,335,238,337,235,340,232,337,2,2,231,337,2,2,231,336,236,338,235,339,234,338,235,338,235,339,234,340,6464,1,572,1,572,1,571,2,571,2,569,4,568,5,568,5,567,6,567,6,568,5,567,6,566,7,565,8,565,8,563,10,561,12,560,13,559,14,558,15,555,18,554,19,553,20,552,21,551,22,550,23,549,24,545,28,543,30,497,5,38,33,492,11,34,36,462,4,24,13,20,50,459,10,19,16,16,53,456,19,10,26,7,55,454,21,4,94,453,120,451,122,450,123,450,123,448,125,446,127,445,128,445,128,445,128,445,128,445,128,449,124,449,124,449,124,449,124,449,124,449,124,450,123,450,123,450,123,450,123,450,123,449,124,449,124,448,128,445,129,443,131,442,132,441,133,439,135,438,137,436,139,433,141,432,141,432,142,431,142,431,143,430,143,430,143,430,143,429,145,427,146,427,147,426,147,425,148,425,148,424,149,423,151,422,151,422,151,422,151,422,151,421,153,420,153,419,154,419,154,418,155,418,156,416,157,415,158,415,2,1,156,413,2,1,2,1,154,413,5,1,154,412,1,2,2,2,154,412,1,1,3,1,156,410,2,1,2,2,156,410,2,4,157,416,157,415,159,414,159,414,159,413,160,413,161,411,162,411,162,411,162,411,163,410,163,411,162,412,161,40,4,368,162,39,4,368,162,39,4,368,162,40,2,369,162,411,163,410,163,410,163,410,164,410,2,2,159,50,3,357,3,2,158,50,4,357,2,2,158,50,4,365,154,51,3,367,153,51,1,369,152,423,150,419,1,5,6,4,138,418,2,19,134,442,3,7,121,455,118,456,117,457,87,1,28,458,86,3,28,456,86,4,28,456,85,5,27,456,85,7,25,458,83,8,23,460,82,8,23,461,81,9,22,460,82,10,21,460,82,11,19,461,82,12,18,2,2,457,82,13,17,1,3,457,8,1,73,14,16,1,4,456,8,2,72,14,21,457,6,3,72,14,21,458,5,2,73,15,20,460,2,3,73,17,18,460,2,3,73,18,17,461,1,3,2,3,68,17,18,465,1,5,67,17,17,471,68,18,16,471,30,3,35,18,16,471,29,4,35,18,15,472,25,7,36,18,15,473,24,7,36,18,15,475,21,8,36,18,15,477,18,10,37,19,12,477,18,11,36,18,13,477,17,12,35,19,2,1,10,477,16,13,34,20,2,1,10,480,1,1,10,15,33,24,8,484,3,1,4,18,31,24,8,484,1,3,3,19,31,24,8,489,1,20,31,24,8,510,31,24,7,512,29,25,7,512,26,28,6,515,23,30,5,515,9,3,10,31,4,518,3,7,7,35,2,521,1,7,6,568,3,558,3,8,4,556,6,4,7,553,10,3,4,557,9,2,5,557,9,2,2,2,1,557,3,1,4,7,1,558,2,6253,3,570,5,570,3,561,2,10,3,559,1,8,8,566,1,1,7,545,1,19,9,542,5,17,10,540,6,17,10,539,7,18,10,537,7,19,13,531,9,22,14,442,1,84,8,27,14,439,1,83,9,29,15,23,3,495,7,31,15,23,1,535,14,24,2,505,12,20,1,6,2,4,3,9,1,8,3,480,3,15,2,1,18,1,3,2,7,2,1,14,2,9,3,7,4,477,10,1,3,3,1,2,16,1,17,2,2,24,2,8,4,473,4,1,15,1,2,1,10,2,2,4,9,1,6,8,1,30,3,467,2,1,1,1,5,1,7,1,7,1,2,1,9,10,2,17,6,30,2,1,1,460,2,3,4,2,11,1,8,6,5,12,1,18,7,3,1,25,4,13,2,442,5,2,5,2,5,1,14,43,2,1,2,4,1,26,1,15,4,439,5,1,8,2,4,4,5,5,1,95,5,430,4,2,15,4,1,7,3,67,1,34,5,424,26,118,5,419,24,125,5,417,26,125,5,415,28,125,5,413,23,2,3,41,1,85,5,401,32,49,2,85,4,399,34,126,2,8,4,396,42,4,1,116,3,7,4,175,2,215,49,1,1,5,2,109,1,1,1,8,2,393,49,7,2,111,2,402,38,4,1,46,1,79,2,399,24,5,9,54,1,21,2,57,1,394,22,13,3,2,1,56,1,21,1,452,23,13,3,59,1,475,1,2,19,75,1,13,2,464,17,90,2,464,13,74,7,9,1,2,5,2,1,459,11,32,2,41,8,8,2,1,6,2,1,451,1,8,1,84,7,9,2,1,6,74,1,378,2,2,1,2,3,85,7,9,1,2,5,74,2,66,2,309,11,85,7,12,5,65,2,7,2,66,2,296,1,11,12,86,6,7,4,1,6,63,2,7,3,66,1,296,3,9,13,86,7,6,4,3,4,61,4,5,5,374,14,86,7,6,6,2,3,61,4,3,7,373,15,86,7,6,9,62,5,3,7,372,16,87,5,7,11,47,2,11,6,1,8,370,18,87,5,7,11,46,3,12,14,369,19,87,5,6,9,2,1,21,3,6,3,11,5,12,14,368,20,55,2,7,1,21,6,5,9,23,7,4,5,8,6,11,15,367,21,55,4,5,2,20,7,3,9,23,8,4,1,2,2,2,11,12,15,366,22,55,6,3,3,19,7,2,9,23,9,1,1,2,1,1,16,11,16,365,23,55,12,16,1,2,7,2,10,22,8,2,1,1,18,11,16,365,24,54,13,15,11,2,10,22,8,5,16,10,17,365,25,37,2,10,2,2,13,16,10,3,10,24,4,6,14,12,18,364,26,37,7,5,17,16,10,4,9,36,6,2,2,15,3,2,12,363,28,36,8,1,20,16,10,4,9,67,9,1,1,354,1,7,29,9,5,16,2,4,29,16,11,3,8,73,4,356,2,5,30,2,4,3,5,12,40,14,13,1,8,67,6,1,3,356,2,6,35,3,6,12,40,15,20,25,2,38,14,354,2,6,35,5,5,12,41,15,19,25,1,38,16,353,2,5,37,5,3,12,42,16,17,25,2,25,2,11,14,355,1,5,30,1,4,23,42,16,16,26,2,23,5,9,15,352,3,6,25,6,3,24,41,17,16,13,1,3,6,1,6,21,5,9,15,352,2,6,27,1,7,24,41,18,16,8,1,7,13,7,2,1,1,12,3,9,15,352,1,7,26,1,8,23,42,18,17,9,2,4,6,13,6,21,18,359,24,5,6,23,42,18,19,3,1,1,4,23,5,18,22,347,3,8,25,5,5,17,2,6,42,17,20,2,5,25,3,18,22,347,4,8,25,6,4,17,1,7,43,16,21,1,5,45,23,4,1,341,4,8,26,31,1,2,45,15,9,3,13,47,3,1,19,3,2,341,4,8,26,31,49,14,8,4,10,3,1,45,4,1,19,4,1,341,3,8,26,32,50,14,7,5,14,26,2,2,1,13,3,2,19,346,3,8,24,33,53,12,5,8,1,3,9,23,8,20,13,360,23,35,53,13,4,16,5,23,4,1,2,23,9,361,23,4,2,29,54,14,2,10,2,7,1,24,5,1,2,14,3,7,7,351,2,9,24,3,3,28,54,13,3,10,2,32,4,1,2,15,6,5,4,353,2,8,25,4,1,1,2,26,54,13,3,45,1,2,3,13,8,363,1,7,25,5,4,26,54,13,3,48,3,8,2,4,7,362,2,6,28,4,1,28,54,14,2,46,1,1,2,9,1,6,4,370,30,4,1,28,54,14,3,45,1,1,2,389,30,33,55,14,3,19,4,24,2,5,1,383,29,34,56,13,4,3,2,3,2,7,9,20,2,2,3,375,2,7,27,35,57,14,30,18,8,374,3,6,30,1,1,1,1,29,58,13,30,17,8,374,4,6,28,3,1,1,1,1,2,26,59,1,5,7,30,16,7,375,4,6,27,1,1,3,5,27,64,8,1,1,20,1,7,16,6,374,4,7,23,8,2,1,3,27,64,11,12,10,5,16,2,1,5,371,4,7,24,6,6,29,63,12,5,18,5,14,9,373,1,8,24,5,7,29,62,14,2,21,4,14,9,381,21,1,1,5,9,30,10,2,48,38,5,14,8,380,22,5,10,32,8,4,45,42,3,14,4,1,3,373,1,5,23,4,11,32,3,9,44,43,3,14,4,3,1,372,2,3,21,2,1,3,12,35,1,9,44,60,4,370,2,7,18,2,2,6,13,45,44,61,2,370,3,7,18,8,14,46,45,60,2,2,1,42,1,322,4,8,17,8,15,47,44,61,2,1,2,41,3,320,3,8,17,7,16,2,2,44,43,63,5,40,4,329,17,8,15,3,1,9,2,18,1,15,42,65,4,40,6,326,18,8,15,13,2,18,1,17,40,66,3,40,7,325,17,9,15,16,2,38,34,48,1,19,2,40,7,173,1,150,16,10,16,59,31,48,1,61,8,322,16,10,17,60,29,111,9,318,17,11,17,62,29,110,10,317,15,13,17,29,3,31,26,1,1,110,10,316,15,13,18,29,3,31,28,85,1,24,11,313,16,14,19,28,3,32,28,48,2,59,12,169,1,141,17,14,19,29,1,34,26,49,2,59,13,309,17,15,19,65,26,48,1,60,13,308,17,16,19,66,26,55,2,51,14,307,17,15,20,66,28,52,2,52,15,305,17,16,19,67,30,51,1,52,16,304,16,17,19,70,27,51,2,51,16,303,8,2,3,1,2,16,20,72,24,53,2,51,17,302,6,26,20,73,23,53,2,51,18,302,3,29,18,79,22,49,1,52,18,302,1,31,17,79,25,3,1,96,19,301,1,31,16,80,25,3,3,94,20,204,6,122,14,82,25,5,1,94,20,203,9,119,15,85,20,102,21,201,12,114,2,1,13,87,18,104,21,201,12,113,16,89,16,105,22,200,13,112,1,1,13,90,14,107,22,199,14,75,2,36,13,92,10,20,4,24,2,60,23,198,14,74,3,36,12,93,10,20,4,23,3,60,24,197,14,74,3,35,8,99,9,44,7,59,24,197,14,74,2,35,8,101,8,42,9,59,24,197,14,109,10,101,6,28,2,13,10,59,25,196,13,110,9,103,4,29,3,11,11,59,25,196,13,74,1,30,1,4,9,106,1,29,3,11,11,2,1,56,26,195,12,74,2,30,1,1,1,1,10,105,2,43,10,3,1,56,26,195,12,73,1,1,1,30,14,105,3,29,2,11,9,4,2,55,26,179,4,12,11,74,1,32,14,136,3,10,10,4,2,55,27,177,6,11,11,107,13,137,3,11,10,2,3,55,27,176,8,11,9,107,14,138,3,10,16,54,27,175,9,11,9,107,12,31,1,76,1,31,3,2,1,8,15,54,28,173,11,10,8,109,11,30,3,75,1,31,4,1,5,4,16,53,28,173,11,9,8,75,1,34,11,30,5,7,1,65,1,32,3,1,5,3,17,53,29,171,14,7,1,1,6,75,1,34,11,30,5,75,1,30,9,1,19,53,29,171,19,4,5,112,6,1,3,30,6,73,2,31,28,53,30,169,18,6,4,113,6,3,2,29,8,72,2,31,27,53,30,169,18,5,4,114,6,3,2,29,10,70,3,33,23,54,31,168,18,4,4,115,5,5,1,30,9,1,1,69,3,32,23,54,31,168,19,120,1,2,4,36,11,69,4,32,6,1,15,54,31,167,20,122,5,36,11,70,4,31,5,2,15,54,32,166,21,121,5,30,1,6,11,70,4,32,2,4,14,50,2,2,32,166,24,79,2,37,6,29,1,3,15,70,4,39,11,51,2,2,33,164,25,79,2,37,6,28,2,2,16,71,4,38,10,53,1,2,34,163,25,79,2,36,8,25,3,1,21,69,3,27,2,2,1,7,10,55,34,163,25,116,2,1,6,23,29,68,3,25,7,5,1,2,8,55,34,162,26,118,7,23,2,1,27,68,2,23,6,1,1,6,1,4,6,55,35,161,26,119,7,21,33,66,3,22,7,12,5,56,35,161,26,81,1,38,6,21,34,66,4,19,8,12,5,56,36,159,27,81,2,33,3,1,6,21,36,65,3,19,9,1,4,6,4,57,37,158,27,80,3,32,1,1,2,1,7,20,37,65,3,19,5,1,8,5,4,57,37,157,28,80,4,31,1,1,10,17,1,2,39,64,4,19,6,1,5,5,1,2,1,57,38,156,28,81,3,34,10,18,40,64,6,17,7,1,4,8,2,56,38,155,30,80,2,32,2,2,9,15,1,1,42,64,4,18,4,1,3,1,2,2,3,1,2,1,2,56,38,154,31,80,3,31,2,2,10,13,45,63,3,14,3,1,10,5,3,1,2,59,38,153,33,79,3,31,1,1,12,13,45,64,2,14,11,1,3,3,4,1,2,59,38,153,33,80,2,33,11,13,46,64,2,14,6,1,4,1,3,3,4,2,1,59,38,153,34,78,3,35,9,5,54,65,1,15,13,2,1,1,4,62,38,152,35,79,2,35,10,4,54,67,1,13,6,1,3,2,2,3,3,63,39,1,1,149,35,79,3,32,1,1,10,4,55,66,1,13,7,5,2,1,5,63,41,149,35,79,3,32,12,5,53,81,8,3,3,1,5,63,40,149,36,80,2,33,11,5,55,66,1,12,8,3,1,1,1,1,5,1,3,59,40,149,36,114,72,65,2,12,8,7,9,59,40,149,36,113,72,67,3,9,4,12,2,1,6,59,39,149,37,113,72,66,4,10,1,14,2,1,5,60,39,149,37,113,72,66,2,24,2,1,8,60,39,149,36,114,72,74,3,3,1,6,2,2,3,4,5,60,39,149,36,113,72,74,4,2,2,7,5,4,6,60,40,147,37,113,73,73,4,3,1,2,2,3,5,2,8,60,9,2,29,147,37,112,74,72,6,2,1,2,2,3,4,3,8,63,4,6,5,1,5,5,11,147,37,112,73,73,6,10,4,3,8,94,6,15,4,127,38,112,73,73,5,13,1,1,10,96,4,15,7,124,39,112,73,72,7,9,2,3,2,5,2,115,7,125,39,111,74,71,7,9,2,1,5,122,5,126,40,112,72,71,7,3,2,2,2,1,1,1,6,122,2,129,41,110,73,81,2,2,2,3,5,254,41,89,1,1,6,13,73,70,2,4,3,2,2,1,3,2,5,254,47,83,10,12,72,74,6,4,3,1,7,254,48,82,10,11,73,74,7,1,5,1,6,254,49,82,12,9,72,75,21,1,3,249,53,78,14,7,71,76,21,1,3,248,56,77,15,4,71,76,9,1,7,1,2,3,3,248,57,76,16,3,70,76,3,1,6,3,5,6,2,248,58,76,17,1,71,75,10,265,58,77,16,1,70,75,13,263,59,76,85,77,14,262,61,74,84,78,11,1,2,262,63,72,82,80,10,2,2,261,65,71,81,81,10,86,1,178,66,70,80,81,11,86,3,176,67,68,80,82,12,85,4,3,9,163,69,66,79,83,12,85,17,5,1,156,71,64,78,83,13,85,25,153,72,63,79,83,3,1,9,85,26,152,73,58,1,3,79,84,1,2,10,84,27,151,74,57,2,1,79,88,12,82,30,2,2,144,75,57,80,89,13,81,41,137,76,55,79,91,13,81,44,133,78,53,80,19,6,66,13,81,46,131,79,53,78,18,9,66,13,80,46,131,81,52,77,18,10,65,13,80,46,131,80,1,3,47,79,18,12,63,14,79,46,131,86,42,2,1,79,18,12,63,14,79,47,130,87,41,83,17,13,61,15,79,47,129,90,38,84,17,13,61,14,80,51,11,1,113,90,37,85,17,13,62,12,81,57,2,6,111,91,35,86,18,13,61,12,81,66,110,92,33,89,18,11,61,12,81,66,110,91,33,91,17,13,59,12,81,66,110,91,33,92,17,12,60,11,81,66,111,90,32,93,21,7,61,11,81,73,104,91,31,94,24,2,62,7,2,3,80,74,103,92,29,95,20,4,68,1,5,2,80,74,103,96,1,9,15,97,17,5,156,75,88,5,9,108,2,2,9,101,13,5,156,75,86,10,5,110,1,2,9,100,14,5,68,1,3,1,83,82,78,13,3,116,1,1,4,101,12,5,69,1,87,82,77,14,3,116,1,1,3,102,12,7,68,2,85,82,76,16,2,118,1,106,11,5,69,1,86,82,76,16,1,229,4,3,1,7,154,82,75,16,2,246,152,81,75,17,2,249,149,82,73,19,1,250,148,82,5,1,66,272,4,2,141,82,4,2,65,279,141,83,1,2,1,2,63,281,56,1,83,83,1,3,1,1,63,281,56,2,82,87,65,2,5,277,137,88,72,277,1,2,49,1,83,89,65,283,1,3,132,90,62,285,1,4,131,91,60,286,1,5,130,92,58,293,1,1,128,93,57,297,1,1,124,94,55,302,122,94,54,305,29,1,90,95,52,309,25,3,89,95,49,312,25,3,89,95,48,314,22,5,89,93,49,315,22,5,89,92,50,316,20,6,89,92,49,317,20,7,88,91,50,321,16,8,87,90,51,321,16,8,87,90,51,322,15,9,86,89,49,326,14,9,86,89,49,327,13,9,86,88,50,327,13,10,85,87,50,328,14,9,85,85,52,331,11,9,85,83,41,2,1,342,11,8,85,81,41,348,10,8,85,79,35,4,1,351,11,8,84,78,29,364,10,8,84,77,26,368,11,7,84,76,25,371,10,8,83,75,24,374,10,7,11,1,71,75,21,380,8,6,11,2,70,74,19,384,8,5,13,2,68,74,17,386,9,4,14,1,68,57,1,15,15,387,12,1,85,53,2,2,2,14,13,390,97,51,1,2,7,12,11,391,98,45,17,11,8,395,35,1,61,44,4,1,14,10,7,397,96,44,21,8,5,399,96,42,24,6,6,400,95,41,26,6,4,402,94,41,28,4,4,402,94,42,28,3,4,402,94,42,28,3,4,403,93,42,30,1,4,404,92,42,34,405,92,42,34,406,91,42,24,5,5,406,91,42,19,3,1,7,3,407,91,35,1,6,18,11,2,410,90,35,2,5,16,426,42,1,46,34,3,5,14,428,42,2,45,34,4,3,14,431,40,2,45,33,2,1,2,2,14,433,40,1,45,33,2,1,17,435,39,2,44,33,1,2,16,436,39,3,43,33,17,438,41,2,42,33,16,439,42,1,42,33,15,441,84,32,16,440,85,33,15,442,83,32,14,444,83,31,14,445,83,30,14,446,83,30,12,450,81,29,12,450,43,1,38,28,12,443,1,4,2,3,41,1,38,27,13,444,1,2,3,3,80,27,12,446,51,1,36,26,13,447,50,2,35,25,13,449,49,2,35,25,13,451,48,2,34,25,13,452,48,2,33,24,13,453,83,24,13,452,84,23,14,451,85,23,13,454,83,23,13,454,83,22,13,455,83,22,13,455,83,21,13,453,86,21,12,454,86,21,12,451,89,20,12,452,89,20,12,452,89,19,9,455,90,22,5,456,90,25,1,456,61,3,27,25,1,455,62,3,27,481,65,2,25,480,67,1,25,480,67,1,25,479,68,2,24,475,67,5,26,473,69,6,25,473,66,1,3,2,1,2,25,474,68,6,25,475,41,3,23,8,23,475,42,4,21,8,23,476,42,4,10,2,7,10,22,477,42,3,11,1,7,10,22,478,57,1,5,10,22,479,56,1,4,1,1,9,22,480,55,1,3,13,21,481,35,1,20,1,1,13,21,482,34,2,1,2,16,6,1,8,21,482,35,4,17,14,21,484,31,7,18,13,20,484,32,1,1,7,15,14,19,485,32,8,14,1,2,12,19,471,4,12,30,11,8,1,6,11,19,471,5,13,29,11,7,1,6,11,3,3,13,472,5,13,28,11,7,2,6,8,4,5,12,472,6,15,25,15,3,2,7,3,2,2,2,2,1,4,12,465,1,5,8,15,25,15,3,1,9,2,6,7,11,463,17,14,25,14,14,4,5,6,11,462,19,4,4,5,25,16,12,5,1,2,2,6,10,463,27,1,2,2,24,18,10,10,1,6,9,463,56,18,12,7,2,7,2,1,5,464,53,21,12,6,1,11,5,468,48,22,13,7,1,10,4,471,45,22,14,8,2,8,3,472,45,21,15,8,3,6,3,51,5,417,11,2,32,21,15,9,1,7,2,45,11,417,11,4,32,19,15,10,1,7,1,43,13,418,12,2,19,1,1,4,7,18,17,10,1,5,2,41,15,418,13,3,17,7,5,19,18,11,1,3,2,40,16,419,10,2,1,3,17,9,1,20,19,12,2,40,18,421,8,7,16,30,20,10,3,39,19,422,8,7,16,29,20,12,2,37,20,424,7,7,15,29,21,49,21,425,6,9,15,27,23,46,22,426,6,9,13,27,26,44,22,426,7,10,11,26,30,40,23,427,7,11,10,24,32,6]::integer[]) with ordinality as t(v, ord)
), p as (
  select ord, sum(v) over (order by ord) as pos from d
)
insert into public.sfere_land (start, stop)
select a.pos, b.pos from p a join p b on b.ord = a.ord + 1 where a.ord % 2 = 1;

create or replace function public.sfere_is_land(p_row integer, p_col integer)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select l.stop > p_row * 573 + p_col
    from public.sfere_land l
    where l.start <= p_row * 573 + p_col
    order by l.start desc
    limit 1
  ), false)
$$;

-- ============================================================ enforce it
-- A trigger rather than a check in claim_square, so no path can place a Square on water.

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
  return new;
end;
$$;

drop trigger if exists squares_on_land on public.squares;
create trigger squares_on_land
  before insert or update of "row", col on public.squares
  for each row execute function public.squares_on_land();

-- ============================================================ move Squares off the water
-- Agents follow their home Square when it moves.
alter table public.agents drop constraint if exists agents_home_row_home_col_fkey;
alter table public.agents add constraint agents_home_row_home_col_fkey
  foreign key (home_row, home_col) references public.squares ("row", col)
  on delete restrict on update cascade;

do $$
declare
  s record;
  v_face integer;
  v_y integer;
  v_to record;
  k integer;
begin
  for s in select "row", col from public.squares q where not public.sfere_is_land(q."row", q.col) loop
    v_face := s."row" / 573;
    v_y := s."row" % 573;
    v_to := null;
    -- Nearest open land on the same face, searching outward ring by ring (up to ~400 miles).
    k := 1;
    while v_to is null and k <= 40 loop
      select v_face * 573 + y as r, x as c into v_to
      from generate_series(greatest(0, v_y - k), least(572, v_y + k)) y,
           generate_series(greatest(0, s.col - k), least(572, s.col + k)) x
      where greatest(abs(y - v_y), abs(x - s.col)) = k
        and public.sfere_is_land(v_face * 573 + y, x)
        and not exists (select 1 from public.squares o where o."row" = v_face * 573 + y and o.col = x)
      order by (y - v_y) ^ 2 + (x - s.col) ^ 2
      limit 1;
      k := k + 1;
    end loop;
    -- Far out at sea: the nearest open land cell in grid order.
    if v_to is null then
      select c / 573 as r, c % 573 as c into v_to
      from public.sfere_land l, generate_series(l.start, l.stop - 1) c
      where not exists (select 1 from public.squares o where o."row" = c / 573 and o.col = c % 573)
      order by abs(c - (s."row" * 573 + s.col))
      limit 1;
    end if;
    update public.squares set "row" = v_to.r, col = v_to.c where "row" = s."row" and col = s.col;
  end loop;
end $$;

-- ============================================================ access
revoke all on function public.sfere_is_land(integer, integer) from public;
grant execute on function public.sfere_is_land(integer, integer) to anon, authenticated;
revoke all on function public.squares_on_land() from public, anon, authenticated;

-- ======================================================================= 007_capital_market.sql

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

-- ======================================================================= 008_bank_mines.sql

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

commit;
