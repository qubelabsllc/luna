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
