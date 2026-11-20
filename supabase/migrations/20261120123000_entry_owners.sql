-- Owners of the extensions page's entries: a member who maintains an entry and can edit it from any
-- device, besides the admins. Ownership is separate from authorship: author_name stays who wrote the
-- entry and is shown as before; the owner is who looks after it. An entry may have no owner.
--
-- How an entry gets an owner:
-- - Added by a signed-in member (through the page's functions, or directly for a use case of the
--   adoption map): that member owns it.
-- - Claimed: a signed-in member who holds the entry's edit key (its anonymous author, who has since
--   joined) can claim an entry that has no owner.
-- - Assigned: an admin can give an entry that has no owner to any member, themselves included; an
--   owner can hand their entry to another member, or let it go.
--
-- What does not change:
-- - The edit key keeps working whoever owns the entry, so an anonymous author is never locked out.
-- - Changing the owner is not a change of content, so it makes no version.
-- - Owners are kept in a private table, like the email addresses and edit keys. The page learns only
--   whether an entry is a member's (by_member), and a signed-in member which entries are theirs.
-- - A second (alias) account counts as its member, as everywhere else.

create table private.entry_owners (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid unique references public.extensions (id) on delete cascade,
  use_case_id uuid unique references public.use_cases (id) on delete cascade,
  owner_id uuid not null references public.members (user_id) on delete cascade,
  assigned_by uuid references public.members (user_id) on delete set null,
  assigned_at timestamptz not null default now(),
  check (num_nonnulls(extension_id, use_case_id) = 1)
);

create index entry_owners_owner_idx on private.entry_owners (owner_id);

alter table private.entry_owners enable row level security;
revoke all on private.entry_owners from public, anon, authenticated;

-- Who may edit: an admin, the edit key's holder, or now the owner.
create or replace function private.extensions_page_may_edit(p_extension_id uuid, p_use_case_id uuid, p_edit_key text)
  returns boolean
  language sql stable set search_path = ''
as $$
  select coalesce(private.is_library_admin(), false)
      or (coalesce(p_edit_key, '') <> '' and exists (
            select 1 from private.extensions_page_secrets s
             where s.edit_key_hash = private.extensions_page_hash(p_edit_key)
               and (s.extension_id = p_extension_id or s.use_case_id = p_use_case_id)))
      or exists (
            select 1 from private.entry_owners o
             where o.owner_id = private.current_member_id()
               and (o.extension_id = p_extension_id or o.use_case_id = p_use_case_id));
$$;

-- A member who adds an entry owns it. A trigger rather than a change to add_extension and
-- add_use_case, so that those keep their code; it also covers use cases members add directly.
create function private.entry_owners_on_add() returns trigger
  language plpgsql security definer set search_path = ''
as $$
declare
  v_member uuid := private.current_member_id();
begin
  if v_member is not null then
    if tg_table_name = 'extensions' then
      insert into private.entry_owners (extension_id, owner_id, assigned_by) values (new.id, v_member, v_member);
    else
      insert into private.entry_owners (use_case_id, owner_id, assigned_by) values (new.id, v_member, v_member);
    end if;
  end if;
  return null;
end;
$$;

create trigger entry_owners_on_add after insert on public.extensions
  for each row execute function private.entry_owners_on_add();
create trigger entry_owners_on_add after insert on public.use_cases
  for each row execute function private.entry_owners_on_add();

-- The entry an owner function is about: exactly one, by kind and id. Hidden entries are left to admins.
create function private.entry_owner_target(p_kind text, p_id uuid, out o_extension_id uuid, out o_use_case_id uuid)
  language plpgsql stable set search_path = ''
as $$
begin
  if p_kind = 'extension' then
    if not exists (select 1 from public.extensions where id = p_id and (not hidden or private.is_library_admin())) then
      raise exception 'That entry does not exist.';
    end if;
    o_extension_id := p_id;
  elsif p_kind = 'use_case' then
    if not exists (select 1 from public.use_cases where id = p_id and (not hidden or private.is_library_admin())) then
      raise exception 'That entry does not exist.';
    end if;
    o_use_case_id := p_id;
  else
    raise exception 'Unknown kind of entry.';
  end if;
end;
$$;

revoke execute on function private.entry_owners_on_add(), private.entry_owner_target from public, anon, authenticated;

-- Claim an entry that has no owner, with its edit key, as the signed-in member.
create function public.claim_entry(p_kind text, p_id uuid, p_edit_key text)
  returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_member uuid := private.current_member_id();
  v_ext uuid;
  v_uc uuid;
begin
  if v_member is null then
    raise exception 'Sign in as a member to claim an entry.';
  end if;
  select o_extension_id, o_use_case_id into v_ext, v_uc from private.entry_owner_target(p_kind, p_id);
  perform private.extensions_page_limit('content', 1);
  if coalesce(p_edit_key, '') = '' or not exists (
       select 1 from private.extensions_page_secrets s
        where s.edit_key_hash = private.extensions_page_hash(p_edit_key)
          and (s.extension_id = v_ext or s.use_case_id = v_uc)) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  if exists (select 1 from private.entry_owners where extension_id = v_ext or use_case_id = v_uc) then
    raise exception 'That entry already has an owner.';
  end if;
  insert into private.entry_owners (extension_id, use_case_id, owner_id, assigned_by)
  values (v_ext, v_uc, v_member, v_member);
  return jsonb_build_object('id', p_id, 'owned', true);
end;
$$;

-- Give an entry to a member (p_member), or let it go (p_member null). Admins can give any entry that
-- has no owner; an owner can give theirs away or let it go.
create function public.assign_entry_owner(p_kind text, p_id uuid, p_member uuid)
  returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_me uuid := private.current_member_id();
  v_admin boolean := coalesce(private.is_library_admin(), false);
  v_ext uuid;
  v_uc uuid;
  v_owner uuid;
  v_target uuid;
begin
  if v_me is null then
    raise exception 'Sign in as a member to do that.';
  end if;
  select o_extension_id, o_use_case_id into v_ext, v_uc from private.entry_owner_target(p_kind, p_id);
  select owner_id into v_owner from private.entry_owners
   where extension_id = v_ext or use_case_id = v_uc for update;
  if v_owner is distinct from v_me and not (v_owner is null and v_admin) then
    raise exception 'Only the entry''s owner, or an admin for an entry without one, can do that.';
  end if;
  if p_member is not null then
    select coalesce(m.alias_of, m.user_id) into v_target from public.members m where m.user_id = p_member;
    if v_target is null then
      raise exception 'That person is not a member.';
    end if;
  end if;
  delete from private.entry_owners where extension_id = v_ext or use_case_id = v_uc;
  if v_target is not null then
    insert into private.entry_owners (extension_id, use_case_id, owner_id, assigned_by)
    values (v_ext, v_uc, v_target, v_me);
  end if;
  return jsonb_build_object('id', p_id, 'owner_id', v_target);
end;
$$;

-- The entries the signed-in member owns, so the page can offer to edit them without a key.
create function public.my_entries()
  returns jsonb
  language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'extensions', coalesce((select jsonb_agg(o.extension_id) from private.entry_owners o
                             where o.owner_id = private.current_member_id() and o.extension_id is not null), '[]'::jsonb),
    'use_cases', coalesce((select jsonb_agg(o.use_case_id) from private.entry_owners o
                            where o.owner_id = private.current_member_id() and o.use_case_id is not null), '[]'::jsonb));
$$;

-- Which shown entries are a member's: ids and kinds only, no account ids.
create view public.entries_by_members with (security_invoker = false, security_barrier = true) as
select 'extension'::text as kind, o.extension_id as id
  from private.entry_owners o join public.extensions e on e.id = o.extension_id
 where not e.hidden
union all
select 'use_case', o.use_case_id
  from private.entry_owners o join public.use_cases u on u.id = o.use_case_id
 where not u.hidden;

revoke execute on function public.claim_entry, public.assign_entry_owner, public.my_entries
  from public, anon, authenticated;
grant execute on function public.claim_entry, public.assign_entry_owner, public.my_entries to authenticated;
revoke all on public.entries_by_members from public, anon, authenticated;
grant select on public.entries_by_members to anon, authenticated;
