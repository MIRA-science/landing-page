-- MIRA library: a members-only collection of recordings, transcripts and other resources.
--
-- Access rule: only accounts listed in public.members can see, add or change anything,
-- in the tables below and in the private "library" storage bucket. Public sign-up is off
-- in the project's auth settings, so accounts exist only when an admin creates them.

-- Members -------------------------------------------------------------------

create table public.members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  display_name text,
  is_admin boolean not null default false,
  added_at timestamptz not null default now()
);

alter table public.members enable row level security;

create function public.is_member() returns boolean
  language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.members where user_id = (select auth.uid()));
$$;

create function public.is_library_admin() returns boolean
  language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.members where user_id = (select auth.uid()) and is_admin);
$$;

revoke execute on function public.is_member() from public, anon;
revoke execute on function public.is_library_admin() from public, anon;
grant execute on function public.is_member() to authenticated;
grant execute on function public.is_library_admin() to authenticated;

create policy "Members can see the member list"
  on public.members for select to authenticated
  using ((select public.is_member()));

-- Resources -----------------------------------------------------------------

create table public.resources (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 300),
  kind text not null check (kind in ('recording', 'transcript', 'slides', 'document', 'other')),
  collection text check (char_length(collection) <= 200),
  description text check (char_length(description) <= 5000),
  happened_on date,
  object_path text not null unique,
  file_name text not null,
  mime_type text,
  size_bytes bigint check (size_bytes >= 0),
  uploaded_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index resources_listing_idx on public.resources (happened_on desc nulls last, created_at desc);
create index resources_uploaded_by_idx on public.resources (uploaded_by);

alter table public.resources enable row level security;

create policy "Members can see resources"
  on public.resources for select to authenticated
  using ((select public.is_member()));

create policy "Members can add resources"
  on public.resources for insert to authenticated
  with check ((select public.is_member()) and uploaded_by = (select auth.uid()));

create policy "Members can edit resources"
  on public.resources for update to authenticated
  using ((select public.is_member()))
  with check ((select public.is_member()));

create policy "Uploaders and admins can delete resources"
  on public.resources for delete to authenticated
  using ((select public.is_member()) and (uploaded_by = (select auth.uid()) or (select public.is_library_admin())));

-- Editing changes the description of a file, never which file it is or who added it.
create function public.resources_before_update() returns trigger
  language plpgsql set search_path = ''
as $$
begin
  new.object_path := old.object_path;
  new.file_name := old.file_name;
  new.mime_type := old.mime_type;
  new.size_bytes := old.size_bytes;
  new.uploaded_by := old.uploaded_by;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end;
$$;

create trigger resources_before_update
  before update on public.resources
  for each row execute function public.resources_before_update();

-- Nothing here is for signed-out visitors.
revoke all on public.members, public.resources from anon;

-- Files -----------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('library', 'library', false, 5368709120);  -- 5 GB per file

create policy "Members can read library files"
  on storage.objects for select to authenticated
  using (bucket_id = 'library' and (select public.is_member()));

create policy "Members can upload library files"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'library' and (select public.is_member()));

create policy "Uploaders and admins can delete library files"
  on storage.objects for delete to authenticated
  using (bucket_id = 'library' and (select public.is_member())
         and (owner_id = (select auth.uid())::text or (select public.is_library_admin())));
