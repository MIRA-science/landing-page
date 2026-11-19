-- Versions of the extensions page's entries (mira.science/extensions/), for extensions and use cases
-- alike.
--
-- - Each entry has a version number, 1 when added; entries already listed become version 1.
-- - A save by the entry's key holder or a library admin that changes anything a visitor sees (a shown
--   field, the links, the rows, or a use case's picks) makes the next version and moves updated_at to
--   that moment. A save that changes nothing, and hiding or showing an entry, make no version. Such a
--   save still counts its write units as before: the write limits are unchanged.
-- - Each version's content is kept, with its number and time, in a private table no visitor can read.
--   A version holds an extension's rows (or a use case's picks) only when they changed in that version;
--   otherwise it names the earlier version that holds them, so editing the texts of a large extension
--   does not store all its rows again.
-- - A thumbs up records the version it was given to. Giving one again after the entry changed moves
--   that visitor's thumbs up to the current version (still one per visitor per entry); taking it back
--   removes it. The lists count the thumbs up on the current version (support_count) and on earlier
--   versions (earlier_support_count), and show each entry's version_no and updated_at.
--
-- Everything the first migration (20261117120000_extensions.sql) protects stays as it was: visitors read
-- only the three views and write only through the functions; the new table and columns are not
-- granted to any visitor; the two views replaced here keep their options and their grants, which are
-- set again below exactly as the first migration set them.

-- Version numbers -------------------------------------------------------------------------------------

alter table public.extensions add column version_no integer not null default 1 check (version_no >= 1);
alter table public.use_cases add column version_no integer not null default 1 check (version_no >= 1);

-- The version a thumbs up was given to. Thumbs up already given count for version 1; from here on
-- set_entry_support always names the version.
alter table public.supports add column version_no integer not null default 1 check (version_no >= 1);
alter table public.supports alter column version_no drop default;

-- Each version's content -------------------------------------------------------------------------------

create table private.extensions_page_versions (
  id bigint generated always as identity primary key,
  extension_id uuid references public.extensions (id) on delete cascade,
  use_case_id uuid references public.use_cases (id) on delete cascade,
  version_no integer not null check (version_no >= 1),
  content jsonb not null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(extension_id, use_case_id) = 1),
  unique (extension_id, version_no),
  unique (use_case_id, version_no)
);

alter table private.extensions_page_versions enable row level security;
revoke all on private.extensions_page_versions from public, anon, authenticated;

-- What a visitor sees of an extension: its shown fields, its links, and its rows in order. Row ids are
-- left out, since a visitor does not see them; p_with_ids adds them for a stored version.
create function private.extensions_page_extension_fields(p_id uuid)
  returns jsonb
  language sql stable set search_path = ''
as $$
  select jsonb_build_object('name', e.name, 'also_known_as', e.also_known_as, 'purpose', e.purpose,
           'field', e.field, 'status', e.status, 'written_as', e.written_as, 'version', e.version,
           'compared_against', e.compared_against, 'core_relation', e.core_relation, 'contact', e.contact,
           'author_name', e.author_name,
           'links', coalesce((select jsonb_agg(jsonb_build_object('label', k.label, 'url', k.url) order by k.sort_order)
                                from public.extension_links k where k.extension_id = e.id), '[]'::jsonb))
    from public.extensions e
   where e.id = p_id;
$$;

create function private.extensions_page_extension_rows(p_id uuid, p_with_ids boolean)
  returns jsonb
  language sql stable set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', r.name, 'kind', r.kind, 'standing', r.standing,
                                               'core_term', r.core_term, 'note', r.note)
                            || case when p_with_ids then jsonb_build_object('id', r.id) else '{}'::jsonb end
                            order by r.sort_order), '[]'::jsonb)
    from public.extension_rows r
   where r.extension_id = p_id;
$$;

-- What a visitor sees of a use case: its shown fields, and the extensions and rows it picks (by id, so
-- renaming an extension does not count as a change of the use case).
create function private.extensions_page_use_case_fields(p_id uuid)
  returns jsonb
  language sql stable set search_path = ''
as $$
  select jsonb_build_object('title', u.title, 'goal', u.goal, 'gap', u.gap, 'field', u.field,
                            'author_name', u.author_name)
    from public.use_cases u
   where u.id = p_id;
$$;

create function private.extensions_page_use_case_picks(p_id uuid)
  returns jsonb
  language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'extensions', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by e.id)
                              from public.use_case_extensions l join public.extensions e on e.id = l.extension_id
                             where l.use_case_id = p_id), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'extension_id', r.extension_id)
                                       order by r.id)
                        from public.use_case_rows p join public.extension_rows r on r.id = p.row_id
                       where p.use_case_id = p_id), '[]'::jsonb));
$$;

-- Keeps version p_no of an entry. p_full: whether this version stores the rows (extension) or the picks
-- (use case); when false, the version names the earlier version that holds them.
create function private.extensions_page_keep_version(p_extension_id uuid, p_use_case_id uuid, p_no integer,
                                                     p_full boolean)
  returns void
  language plpgsql volatile set search_path = ''
as $$
declare
  v_from integer;
  v_content jsonb;
begin
  if not p_full then
    select coalesce((v.content ->> 'same_as_version')::integer, v.version_no) into v_from
      from private.extensions_page_versions v
     where (v.extension_id = p_extension_id or v.use_case_id = p_use_case_id) and v.version_no = p_no - 1;
  end if;
  if p_extension_id is not null then
    v_content := private.extensions_page_extension_fields(p_extension_id)
                 || case when v_from is null
                         then jsonb_build_object('rows', private.extensions_page_extension_rows(p_extension_id, true))
                         else jsonb_build_object('same_as_version', v_from) end;
  else
    v_content := private.extensions_page_use_case_fields(p_use_case_id)
                 || case when v_from is null
                         then jsonb_build_object('picks', private.extensions_page_use_case_picks(p_use_case_id))
                         else jsonb_build_object('same_as_version', v_from) end;
  end if;
  insert into private.extensions_page_versions (extension_id, use_case_id, version_no, content)
  values (p_extension_id, p_use_case_id, p_no, v_content);
end;
$$;

revoke execute on function private.extensions_page_extension_fields, private.extensions_page_extension_rows,
  private.extensions_page_use_case_fields, private.extensions_page_use_case_picks,
  private.extensions_page_keep_version
  from public, anon, authenticated;

-- Every entry already listed becomes version 1, its content kept as it is now.
insert into private.extensions_page_versions (extension_id, version_no, content, created_at)
select e.id, 1,
       private.extensions_page_extension_fields(e.id)
       || jsonb_build_object('rows', private.extensions_page_extension_rows(e.id, true)),
       e.updated_at
  from public.extensions e;

insert into private.extensions_page_versions (use_case_id, version_no, content, created_at)
select u.id, 1,
       private.extensions_page_use_case_fields(u.id)
       || jsonb_build_object('picks', private.extensions_page_use_case_picks(u.id)),
       u.updated_at
  from public.use_cases u;

-- The write functions, with versions --------------------------------------------------------------
-- Each is the first migration's function with the version steps added; signatures, checks, messages,
-- and write units are unchanged.

create or replace function public.add_extension(
  p_name text,
  p_purpose text,
  p_status text,
  p_author_name text,
  p_also_known_as text default null,
  p_field text default null,
  p_written_as text default null,
  p_version text default null,
  p_compared_against text default null,
  p_core_relation text default null,
  p_contact text default null,
  p_links jsonb default '[]',
  p_rows jsonb default '[]',
  p_email text default null,
  p_trap text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_name text;
  v_aka text;
  v_purpose text;
  v_field text;
  v_status text;
  v_written text;
  v_version text;
  v_compared text;
  v_relation text;
  v_contact text;
  v_links jsonb;
  v_rows jsonb;
  v_author text;
  v_email text;
  v_key text := private.extensions_page_new_key();
  v_id uuid;
begin
  perform private.extensions_page_trap(p_trap);
  v_name := private.extensions_page_text(p_name, 'Name', 120, true);
  v_aka := private.extensions_page_text(p_also_known_as, 'Also known as', 200, false);
  v_purpose := private.extensions_page_text(p_purpose, 'What it is for', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_status := private.extensions_page_status(p_status);
  v_written := private.extensions_page_text(p_written_as, 'Written as', 200, false);
  v_version := private.extensions_page_text(p_version, 'Version', 200, false);
  v_compared := private.extensions_page_text(p_compared_against, 'Compared against', 300, false);
  v_relation := private.extensions_page_text(p_core_relation, 'How it relates to the core', 2000, false);
  v_contact := private.extensions_page_text(p_contact, 'Who to talk to', 300, false);
  v_links := private.extensions_page_links(p_links);
  v_rows := private.extensions_page_rows(p_rows);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  v_email := private.extensions_page_email(p_email);
  -- One unit, plus one for every 10 rows.
  perform private.extensions_page_limit('content', 1 + ceil(jsonb_array_length(v_rows) / 10.0)::integer);

  insert into public.extensions (name, also_known_as, purpose, field, status, written_as, version,
                                 compared_against, core_relation, contact, author_name)
  values (v_name, v_aka, v_purpose, v_field, v_status, v_written, v_version, v_compared, v_relation,
          v_contact, v_author)
  returning id into v_id;

  insert into public.extension_links (extension_id, sort_order, label, url)
  select v_id, x.sort_order, x.label, x.url
    from jsonb_to_recordset(v_links) as x(label text, url text, sort_order smallint);

  insert into public.extension_rows (extension_id, sort_order, name, kind, standing, core_term, note)
  select v_id, x.sort_order, x.name, x.kind, x.standing, x.core_term, x.note
    from jsonb_to_recordset(v_rows) as x(name text, kind text, standing text, core_term text, note text,
                                         sort_order smallint);

  insert into private.extensions_page_secrets (extension_id, email, edit_key_hash)
  values (v_id, v_email, private.extensions_page_hash(v_key));

  perform private.extensions_page_keep_version(v_id, null, 1, true);

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

create or replace function public.add_use_case(
  p_title text,
  p_goal text,
  p_gap text,
  p_author_name text,
  p_field text default null,
  p_extension_ids uuid[] default '{}',
  p_row_ids uuid[] default '{}',
  p_email text default null,
  p_trap text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_title text;
  v_goal text;
  v_gap text;
  v_field text;
  v_author text;
  v_email text;
  v_ids uuid[];
  v_rows uuid[];
  v_key text := private.extensions_page_new_key();
  v_id uuid;
begin
  perform private.extensions_page_trap(p_trap);
  v_title := private.extensions_page_text(p_title, 'Title', 200, true);
  v_goal := private.extensions_page_text(p_goal, 'What you are trying to do', 2000, true);
  v_gap := private.extensions_page_text(p_gap, 'What the core does not let you record', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_ids := array(select distinct x from unnest(coalesce(p_extension_ids, '{}'::uuid[])) as x where x is not null);
  if cardinality(v_ids) > 50 then
    raise exception 'Pick at most 50 extensions.';
  end if;
  if exists (select 1 from unnest(v_ids) as x
              where not exists (select 1 from public.extensions e where e.id = x and not e.hidden)) then
    raise exception 'One of the extensions you picked is no longer listed. Reload the page. Then try again.';
  end if;
  v_rows := private.extensions_page_row_picks(p_row_ids, v_ids);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  v_email := private.extensions_page_email(p_email);
  -- One unit, plus one for every 20 row picks.
  perform private.extensions_page_limit('content', 1 + ceil(cardinality(v_rows) / 20.0)::integer);

  insert into public.use_cases (title, goal, gap, field, author_name)
  values (v_title, v_goal, v_gap, v_field, v_author)
  returning id into v_id;

  insert into public.use_case_extensions (use_case_id, extension_id)
  select v_id, x from unnest(v_ids) as x;

  insert into public.use_case_rows (use_case_id, extension_id, row_id)
  select v_id, r.extension_id, r.id from public.extension_rows r where r.id = any (v_rows);

  insert into private.extensions_page_secrets (use_case_id, email, edit_key_hash)
  values (v_id, v_email, private.extensions_page_hash(v_key));

  perform private.extensions_page_keep_version(null, v_id, 1, true);

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

-- A thumbs up is given to the entry's current version. Giving it again after the entry changed moves
-- it to the current version; taking it back removes it. The counts returned are the current version's
-- and the earlier versions'.
create or replace function public.set_entry_support(
  p_voter uuid,
  p_on boolean,
  p_extension_id uuid default null,
  p_use_case_id uuid default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_version integer;
  v_count integer;
  v_earlier integer;
begin
  if p_voter is null or p_on is null then
    raise exception 'This thumbs up could not be saved.';
  end if;
  perform private.extensions_page_target(p_extension_id, p_use_case_id);
  perform private.extensions_page_limit('support');

  if p_extension_id is not null then
    select version_no into v_version from public.extensions where id = p_extension_id;
    if p_on then
      insert into public.supports (extension_id, voter, version_no) values (p_extension_id, p_voter, v_version)
      on conflict (extension_id, voter) do update
        set version_no = excluded.version_no, created_at = now()
        where public.supports.version_no <> excluded.version_no;
    else
      delete from public.supports where extension_id = p_extension_id and voter = p_voter;
    end if;
    select count(*) filter (where version_no = v_version), count(*) filter (where version_no <> v_version)
      into v_count, v_earlier
      from public.supports where extension_id = p_extension_id;
  else
    select version_no into v_version from public.use_cases where id = p_use_case_id;
    if p_on then
      insert into public.supports (use_case_id, voter, version_no) values (p_use_case_id, p_voter, v_version)
      on conflict (use_case_id, voter) do update
        set version_no = excluded.version_no, created_at = now()
        where public.supports.version_no <> excluded.version_no;
    else
      delete from public.supports where use_case_id = p_use_case_id and voter = p_voter;
    end if;
    select count(*) filter (where version_no = v_version), count(*) filter (where version_no <> v_version)
      into v_count, v_earlier
      from public.supports where use_case_id = p_use_case_id;
  end if;

  return jsonb_build_object('supported', p_on, 'support_count', v_count, 'earlier_support_count', v_earlier,
                            'version_no', v_version);
end;
$$;

-- As in the first migration, and: the entry is locked for the save; what a visitor sees of it is
-- compared before and after; only when it differs does the save make the next version and move
-- updated_at.
create or replace function public.edit_extension(
  p_id uuid,
  p_name text,
  p_purpose text,
  p_status text,
  p_author_name text,
  p_also_known_as text default null,
  p_field text default null,
  p_written_as text default null,
  p_version text default null,
  p_compared_against text default null,
  p_core_relation text default null,
  p_contact text default null,
  p_links jsonb default null,
  p_rows jsonb default null,
  p_edit_key text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_admin boolean := coalesce(private.is_library_admin(), false);
  v_hidden boolean;
  v_name text;
  v_aka text;
  v_purpose text;
  v_field text;
  v_status text;
  v_written text;
  v_version text;
  v_compared text;
  v_relation text;
  v_contact text;
  v_links jsonb;
  v_rows jsonb;
  v_author text;
  v_stray integer;
  v_keep_links boolean := p_links is null or jsonb_typeof(p_links) = 'null';
  v_keep_rows boolean := p_rows is null or jsonb_typeof(p_rows) = 'null';
  v_fields_before jsonb;
  v_rows_before jsonb;
  v_rows_changed boolean;
  v_no integer;
begin
  -- The key comes first, so that without it a hidden entry and a missing one look the same.
  if not private.extensions_page_may_edit(p_id, null, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  select hidden, version_no into v_hidden, v_no from public.extensions where id = p_id for update;
  if not found then
    raise exception 'That entry does not exist.';
  end if;
  if v_hidden and not v_admin then
    raise exception 'That entry is no longer listed. Reload the page.';
  end if;
  v_name := private.extensions_page_text(p_name, 'Name', 120, true);
  v_aka := private.extensions_page_text(p_also_known_as, 'Also known as', 200, false);
  v_purpose := private.extensions_page_text(p_purpose, 'What it is for', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_status := private.extensions_page_status(p_status);
  v_written := private.extensions_page_text(p_written_as, 'Written as', 200, false);
  v_version := private.extensions_page_text(p_version, 'Version', 200, false);
  v_compared := private.extensions_page_text(p_compared_against, 'Compared against', 300, false);
  v_relation := private.extensions_page_text(p_core_relation, 'How it relates to the core', 2000, false);
  v_contact := private.extensions_page_text(p_contact, 'Who to talk to', 300, false);
  if not v_keep_links then
    v_links := private.extensions_page_links(p_links);
  end if;
  if not v_keep_rows then
    v_rows := private.extensions_page_rows(p_rows);
    select min(t.o) into v_stray
      from jsonb_array_elements(v_rows) with ordinality as t(e, o)
     where t.e ->> 'id' is not null
       and not exists (select 1 from public.extension_rows r
                        where r.id = (t.e ->> 'id')::uuid and r.extension_id = p_id);
    if v_stray is not null then
      raise exception 'Row % is no longer part of this extension. Reload the page. Then try again.', v_stray;
    end if;
  end if;
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    -- One unit, plus one for every 10 rows sent.
    perform private.extensions_page_limit('content',
      1 + case when v_keep_rows then 0 else ceil(jsonb_array_length(v_rows) / 10.0)::integer end);
  end if;

  v_fields_before := private.extensions_page_extension_fields(p_id);
  v_rows_before := private.extensions_page_extension_rows(p_id, false);

  update public.extensions
     set name = v_name, also_known_as = v_aka, purpose = v_purpose, field = v_field, status = v_status,
         written_as = v_written, version = v_version, compared_against = v_compared,
         core_relation = v_relation, contact = v_contact, author_name = v_author
   where id = p_id;

  if not v_keep_links then
    delete from public.extension_links where extension_id = p_id;
    insert into public.extension_links (extension_id, sort_order, label, url)
    select p_id, x.sort_order, x.label, x.url
      from jsonb_to_recordset(v_links) as x(label text, url text, sort_order smallint);
  end if;

  if not v_keep_rows then
    delete from public.extension_rows r
     where r.extension_id = p_id
       and not exists (select 1 from jsonb_array_elements(v_rows) as t(e)
                        where t.e ->> 'id' is not null and (t.e ->> 'id')::uuid = r.id);
    update public.extension_rows r
       set sort_order = x.sort_order, name = x.name, kind = x.kind, standing = x.standing,
           core_term = x.core_term, note = x.note
      from jsonb_to_recordset(v_rows) as x(id uuid, name text, kind text, standing text, core_term text,
                                           note text, sort_order smallint)
     where x.id is not null and r.id = x.id and r.extension_id = p_id;
    insert into public.extension_rows (extension_id, sort_order, name, kind, standing, core_term, note)
    select p_id, x.sort_order, x.name, x.kind, x.standing, x.core_term, x.note
      from jsonb_to_recordset(v_rows) as x(id uuid, name text, kind text, standing text, core_term text,
                                           note text, sort_order smallint)
     where x.id is null;
  end if;

  v_rows_changed := private.extensions_page_extension_rows(p_id, false) is distinct from v_rows_before;
  if v_rows_changed or private.extensions_page_extension_fields(p_id) is distinct from v_fields_before then
    update public.extensions set version_no = version_no + 1, updated_at = now()
     where id = p_id
     returning version_no into v_no;
    perform private.extensions_page_keep_version(p_id, null, v_no, v_rows_changed);
  end if;

  return jsonb_build_object('id', p_id, 'version_no', v_no);
end;
$$;

-- As in the first migration, with versions as for an extension: a change of the shown fields or of
-- the picks makes the next version.
create or replace function public.edit_use_case(
  p_id uuid,
  p_title text,
  p_goal text,
  p_gap text,
  p_author_name text,
  p_field text default null,
  p_extension_ids uuid[] default '{}',
  p_row_ids uuid[] default null,
  p_edit_key text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_admin boolean := coalesce(private.is_library_admin(), false);
  v_hidden boolean;
  v_title text;
  v_goal text;
  v_gap text;
  v_field text;
  v_author text;
  v_ids uuid[];
  v_rows uuid[];
  v_keep_picks boolean := p_row_ids is null;
  v_fields_before jsonb;
  v_picks_before jsonb;
  v_picks_changed boolean;
  v_no integer;
begin
  -- The key comes first, so that without it a hidden entry and a missing one look the same.
  if not private.extensions_page_may_edit(null, p_id, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  select hidden, version_no into v_hidden, v_no from public.use_cases where id = p_id for update;
  if not found then
    raise exception 'That entry does not exist.';
  end if;
  if v_hidden and not v_admin then
    raise exception 'That entry is no longer listed. Reload the page.';
  end if;
  v_title := private.extensions_page_text(p_title, 'Title', 200, true);
  v_goal := private.extensions_page_text(p_goal, 'What you are trying to do', 2000, true);
  v_gap := private.extensions_page_text(p_gap, 'What the core does not let you record', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_ids := array(select distinct x from unnest(coalesce(p_extension_ids, '{}'::uuid[])) as x where x is not null);
  if cardinality(v_ids) > 50 then
    raise exception 'Pick at most 50 extensions.';
  end if;
  if exists (select 1 from unnest(v_ids) as x
              where not exists (select 1 from public.extensions e where e.id = x and not e.hidden)) then
    raise exception 'One of the extensions you picked is no longer listed. Reload the page. Then try again.';
  end if;
  if not v_keep_picks then
    v_rows := private.extensions_page_row_picks(p_row_ids, v_ids);
  end if;
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    -- One unit, plus one for every 20 row picks sent.
    perform private.extensions_page_limit('content',
      1 + case when v_keep_picks then 0 else ceil(cardinality(v_rows) / 20.0)::integer end);
  end if;

  v_fields_before := private.extensions_page_use_case_fields(p_id);
  v_picks_before := private.extensions_page_use_case_picks(p_id);

  update public.use_cases
     set title = v_title, goal = v_goal, gap = v_gap, field = v_field, author_name = v_author
   where id = p_id;

  -- Unpicking an extension also drops the use case's picks of its rows (foreign key, on delete cascade).
  delete from public.use_case_extensions l
   where l.use_case_id = p_id
     and l.extension_id <> all (v_ids)
     and exists (select 1 from public.extensions e where e.id = l.extension_id and not e.hidden);
  insert into public.use_case_extensions (use_case_id, extension_id)
  select p_id, x from unnest(v_ids) as x
  on conflict do nothing;

  if not v_keep_picks then
    delete from public.use_case_rows p
     where p.use_case_id = p_id
       and p.row_id <> all (v_rows)
       and exists (select 1 from public.extensions e where e.id = p.extension_id and not e.hidden);
    insert into public.use_case_rows (use_case_id, extension_id, row_id)
    select p_id, r.extension_id, r.id from public.extension_rows r where r.id = any (v_rows)
    on conflict do nothing;
  end if;

  v_picks_changed := private.extensions_page_use_case_picks(p_id) is distinct from v_picks_before;
  if v_picks_changed or private.extensions_page_use_case_fields(p_id) is distinct from v_fields_before then
    update public.use_cases set version_no = version_no + 1, updated_at = now()
     where id = p_id
     returning version_no into v_no;
    perform private.extensions_page_keep_version(null, p_id, v_no, v_picks_changed);
  end if;

  return jsonb_build_object('id', p_id, 'version_no', v_no);
end;
$$;

-- The same rights on the replaced functions as the first migration gave them.
revoke execute on function public.add_extension, public.add_use_case, public.set_entry_support,
  public.edit_extension, public.edit_use_case
  from public, anon, authenticated;
grant execute on function public.add_extension, public.add_use_case, public.set_entry_support,
  public.edit_extension, public.edit_use_case
  to anon, authenticated;

-- What visitors read ----------------------------------------------------------------------------------
-- The two lists keep every column they had, in the same order, and add earlier_support_count and
-- version_no at the end. support_count now counts the thumbs up on the current version. Both stay
-- owner-rights views with security_barrier, for the reasons the first migration gives.

create or replace view public.extensions_shown with (security_invoker = false, security_barrier = true) as
select
  e.id, e.name, e.also_known_as, e.purpose, e.field, e.status, e.written_as, e.version,
  e.compared_against, e.core_relation, e.contact, e.author_name, e.created_at, e.updated_at,
  (select count(*) from public.supports s where s.extension_id = e.id and s.version_no = e.version_no)::integer as support_count,
  (select count(*) from public.comments c where c.extension_id = e.id and not c.hidden)::integer as comment_count,
  coalesce((
    select jsonb_agg(jsonb_build_object('label', k.label, 'url', k.url) order by k.sort_order)
      from public.extension_links k
     where k.extension_id = e.id
  ), '[]'::jsonb) as links,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'name', r.name, 'kind', r.kind, 'standing', r.standing,
             'core_term', r.core_term, 'note', r.note,
             'use_cases', coalesce((
               select jsonb_agg(jsonb_build_object('id', u.id, 'title', u.title) order by u.created_at, u.id)
                 from public.use_case_rows p
                 join public.use_cases u on u.id = p.use_case_id
                where p.extension_id = r.extension_id and p.row_id = r.id   -- both, so use_case_rows_row_idx applies
                  and not u.hidden), '[]'::jsonb))
           order by r.sort_order)
      from public.extension_rows r
     where r.extension_id = e.id
  ), '[]'::jsonb) as rows,
  coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'title', u.title) order by u.created_at, u.id)
      from public.use_case_extensions l
      cross join lateral (select u.id, u.title, u.created_at from public.use_cases u
                           where u.id = l.use_case_id and not u.hidden offset 0) u
     where l.extension_id = e.id
  ), '[]'::jsonb) as use_cases,
  (select count(*) from public.supports s where s.extension_id = e.id and s.version_no <> e.version_no)::integer as earlier_support_count,
  e.version_no
from public.extensions e
where not e.hidden;

create or replace view public.use_cases_shown with (security_invoker = false, security_barrier = true) as
select
  u.id, u.title, u.goal, u.gap, u.field, u.author_name, u.created_at, u.updated_at,
  (select count(*) from public.supports s where s.use_case_id = u.id and s.version_no = u.version_no)::integer as support_count,
  (select count(*) from public.comments c where c.use_case_id = u.id and not c.hidden)::integer as comment_count,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', e.id, 'name', e.name,
             'rows', coalesce((
               select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.sort_order)
                 from public.use_case_rows p
                 join public.extension_rows r on r.id = p.row_id
                where p.use_case_id = u.id and p.extension_id = e.id), '[]'::jsonb))
           order by e.name, e.id)
      from public.use_case_extensions l
      cross join lateral (select e.id, e.name from public.extensions e
                           where e.id = l.extension_id and not e.hidden offset 0) e
     where l.use_case_id = u.id
  ), '[]'::jsonb) as extensions,
  (select count(*) from public.supports s where s.use_case_id = u.id and s.version_no <> u.version_no)::integer as earlier_support_count,
  u.version_no
from public.use_cases u
where not u.hidden;

-- The same rights on the views as the first migration gave them.
revoke all on public.extensions_shown, public.use_cases_shown from public, anon, authenticated;
grant select on public.extensions_shown, public.use_cases_shown to anon, authenticated;
