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
