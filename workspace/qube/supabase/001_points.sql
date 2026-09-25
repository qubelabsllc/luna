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
