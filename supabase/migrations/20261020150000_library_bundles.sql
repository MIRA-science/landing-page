-- Bundles and summaries. A bundle groups the items of one session or event (its summary,
-- recording, transcript and anything else) under one entry; a summary is an item of its own.

create table public.bundles (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 300),
  collection text check (char_length(collection) <= 200),
  happened_on date,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index bundles_created_by_idx on public.bundles (created_by);

alter table public.bundles enable row level security;

create policy "Members can see bundles"
  on public.bundles for select to authenticated
  using ((select private.is_member()));

create policy "Members can add bundles"
  on public.bundles for insert to authenticated
  with check ((select private.is_member()) and created_by = (select auth.uid()));

create policy "Members can edit bundles"
  on public.bundles for update to authenticated
  using ((select private.is_member()))
  with check ((select private.is_member()));

create policy "Creators and admins can delete bundles"
  on public.bundles for delete to authenticated
  using ((select private.is_member()) and (created_by = (select auth.uid()) or (select private.is_library_admin())));

create function private.bundles_before_update() returns trigger
  language plpgsql set search_path = ''
as $$
begin
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  new.updated_at := now();
  return new;
end;
$$;

create trigger bundles_before_update
  before update on public.bundles
  for each row execute function private.bundles_before_update();

revoke all on public.bundles from anon;

-- Items join a bundle; deleting a bundle leaves its items standing on their own.
alter table public.resources add column bundle_id uuid references public.bundles (id) on delete set null;
create index resources_bundle_idx on public.resources (bundle_id);

alter table public.resources drop constraint resources_kind_check;
alter table public.resources add constraint resources_kind_check
  check (kind in ('summary', 'recording', 'transcript', 'slides', 'document', 'other'));

-- A bundle whose last item is deleted or moved out goes too.
create function private.drop_empty_bundle() returns trigger
  language plpgsql security definer set search_path = ''
as $$
begin
  if old.bundle_id is not null and (tg_op = 'DELETE' or new.bundle_id is distinct from old.bundle_id)
     and not exists (select 1 from public.resources where bundle_id = old.bundle_id) then
    delete from public.bundles where id = old.bundle_id;
  end if;
  return null;
end;
$$;

revoke execute on function private.drop_empty_bundle() from public, anon, authenticated;

create trigger resources_drop_empty_bundle
  after delete or update of bundle_id on public.resources
  for each row execute function private.drop_empty_bundle();
