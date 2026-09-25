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
