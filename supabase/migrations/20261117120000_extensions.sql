-- The extensions page (mira.science/extensions/): extensions to MIRA's core schema that people are
-- trying, and the use cases behind them. Anyone can add an extension or a use case, give a thumbs up,
-- and comment, without an account. Entries and comments show at once; library admins can hide them.
--
-- How it is kept safe:
-- - Visitors read only through three views (extensions_shown, use_cases_shown, and comments_shown).
--   They leave out hidden rows and private columns, and carry each entry's thumbs-up and comment counts.
-- - Visitors write only through the functions below. The tables have row-level security on, no
--   policies, and no grants for signed-out or signed-in visitors, so a visitor can never read, add,
--   change, or delete a row directly.
-- - Each write function checks what it is given: required fields, length limits (the tables hold the
--   same limits), links that start with https://, an empty spam-trap field, and how many writes the
--   caller's network address made in the last hour. The address is kept only as a salted hash, and
--   only for a day.
-- - Email addresses and the hashes of the edit keys sit in a private table no visitor can read. The
--   browser that adds an entry is given its edit key once and keeps it; only that key, or a library
--   admin, can change the entry.
-- - Library admins (private.is_library_admin()) can edit, hide, and show again any entry or comment.
--
-- Write limits: 20 entries, comments, and edits an hour from one address; 120 thumbs-up changes an
-- hour from one address; 300 entries, comments, and edits an hour from all addresses together, in
-- case an address can be faked.

-- Entries -------------------------------------------------------------------------------------------

create table public.extensions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> '' and char_length(name) <= 120),
  adds text not null check (btrim(adds) <> '' and char_length(adds) <= 2000),
  field text check (char_length(field) <= 120),
  status text not null check (status in ('idea', 'experimenting', 'in_use')),
  contact text check (char_length(contact) <= 300),
  link text check (char_length(link) <= 500 and link ~ '^https://[^[:space:]]+$'),
  core_relation text check (char_length(core_relation) <= 2000),
  author_name text not null check (btrim(author_name) <> '' and char_length(author_name) <= 120),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.use_cases (
  id uuid primary key default gen_random_uuid(),
  title text not null check (btrim(title) <> '' and char_length(title) <= 200),
  goal text not null check (btrim(goal) <> '' and char_length(goal) <= 2000),   -- what the person is trying to do
  gap text not null check (btrim(gap) <> '' and char_length(gap) <= 2000),      -- what the core does not let them record
  field text check (char_length(field) <= 120),
  author_name text not null check (btrim(author_name) <> '' and char_length(author_name) <= 120),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Which use case needs which extension.
create table public.use_case_extensions (
  use_case_id uuid not null references public.use_cases (id) on delete cascade,
  extension_id uuid not null references public.extensions (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (use_case_id, extension_id)
);

create index use_case_extensions_extension_idx on public.use_case_extensions (extension_id);

-- One row per thumbs up: the entry and a random id kept in the visitor's browser.
create table public.supports (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid references public.extensions (id) on delete cascade,
  use_case_id uuid references public.use_cases (id) on delete cascade,
  voter uuid not null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(extension_id, use_case_id) = 1),
  unique (extension_id, voter),
  unique (use_case_id, voter)
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid references public.extensions (id) on delete cascade,
  use_case_id uuid references public.use_cases (id) on delete cascade,
  body text not null check (btrim(body) <> '' and char_length(body) <= 2000),
  author_name text not null check (btrim(author_name) <> '' and char_length(author_name) <= 120),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(extension_id, use_case_id) = 1)
);

create index comments_extension_idx on public.comments (extension_id, created_at);
create index comments_use_case_idx on public.comments (use_case_id, created_at);

-- Private: email addresses, edit keys, and the write-limit log ---------------------------------------

-- The email address a person gave with an entry (never shown) and the SHA-256 hash of the entry's
-- edit key (the key itself is never stored).
create table private.extensions_page_secrets (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid unique references public.extensions (id) on delete cascade,
  use_case_id uuid unique references public.use_cases (id) on delete cascade,
  email text check (char_length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  edit_key_hash text not null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(extension_id, use_case_id) = 1)
);

-- One row per write, holding a salted hash of the caller's network address. Rows older than a day
-- are deleted on each write.
create table private.extensions_page_writes (
  id bigint generated always as identity primary key,
  caller_hash text not null,
  kind text not null check (kind in ('content', 'support')),
  created_at timestamptz not null default now()
);

create index extensions_page_writes_caller_idx on private.extensions_page_writes (caller_hash, kind, created_at);
create index extensions_page_writes_time_idx on private.extensions_page_writes (created_at);

-- The salt for those hashes, made once here and never shown.
create table private.extensions_page_salt (
  only_row boolean primary key default true check (only_row),
  salt text not null
);

insert into private.extensions_page_salt (salt)
values (replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''));

-- No visitor touches a table directly.
alter table public.extensions enable row level security;
alter table public.use_cases enable row level security;
alter table public.use_case_extensions enable row level security;
alter table public.supports enable row level security;
alter table public.comments enable row level security;
alter table private.extensions_page_secrets enable row level security;
alter table private.extensions_page_writes enable row level security;
alter table private.extensions_page_salt enable row level security;

revoke all on public.extensions, public.use_cases, public.use_case_extensions, public.supports, public.comments
  from public, anon, authenticated;
revoke all on private.extensions_page_secrets, private.extensions_page_writes, private.extensions_page_salt
  from public, anon, authenticated;

-- Checks shared by the write functions -------------------------------------------------------------
-- These run inside the write functions, as their owner. No visitor can call them.

-- A text field: trimmed, empty becomes null, required and length checked. The messages are shown
-- to the visitor as they are, so they name the field as the form does.
create function private.extensions_page_text(p_value text, p_label text, p_max integer, p_required boolean)
  returns text
  language plpgsql stable set search_path = ''
as $$
declare
  v text := nullif(btrim(p_value, E' \t\r\n'), '');
begin
  if v is null then
    if p_required then
      raise exception '“%” is required.', p_label;
    end if;
    return null;
  end if;
  if char_length(v) > p_max then
    raise exception '“%” can be at most % characters. This one has %.',
      p_label, to_char(p_max, 'FM999,999,999'), to_char(char_length(v), 'FM999,999,999');
  end if;
  return v;
end;
$$;

create function private.extensions_page_link(p_value text)
  returns text
  language plpgsql stable set search_path = ''
as $$
declare
  v text := private.extensions_page_text(p_value, 'Where to see it', 500, false);
begin
  if v is null then
    return null;
  end if;
  if left(v, 8) <> 'https://' then
    raise exception '“Where to see it” must start with https://.';
  end if;
  if v !~ '^https://[^[:space:]]+$' then
    raise exception '“Where to see it” must be a single web address without spaces.';
  end if;
  return v;
end;
$$;

create function private.extensions_page_email(p_value text)
  returns text
  language plpgsql stable set search_path = ''
as $$
declare
  v text := private.extensions_page_text(p_value, 'Your email', 254, false);
begin
  if v is not null and v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception '“Your email” does not look like an email address.';
  end if;
  return v;
end;
$$;

create function private.extensions_page_status(p_value text)
  returns text
  language plpgsql immutable set search_path = ''
as $$
begin
  if p_value is null or p_value not in ('idea', 'experimenting', 'in_use') then
    raise exception 'Choose a status.';
  end if;
  return p_value;
end;
$$;

-- The spam trap: a field people never see, so only a program fills it in.
create function private.extensions_page_trap(p_company text)
  returns void
  language plpgsql immutable set search_path = ''
as $$
begin
  if coalesce(p_company, '') <> '' then
    raise exception 'This could not be saved.';
  end if;
end;
$$;

create function private.extensions_page_hash(p_value text)
  returns text
  language sql stable set search_path = ''
as $$
  select encode(sha256(convert_to(p_value, 'UTF8')), 'hex');
$$;

-- 64 hex characters from two random UUIDs (244 random bits).
create function private.extensions_page_new_key()
  returns text
  language sql volatile set search_path = ''
as $$
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
$$;

-- The entry a thumbs up or a comment is for: exactly one, and shown.
create function private.extensions_page_target(p_extension_id uuid, p_use_case_id uuid)
  returns void
  language plpgsql stable set search_path = ''
as $$
begin
  if num_nonnulls(p_extension_id, p_use_case_id) <> 1 then
    raise exception 'Choose one entry.';
  end if;
  if p_extension_id is not null
     and not exists (select 1 from public.extensions where id = p_extension_id and not hidden) then
    raise exception 'That entry is no longer listed. Reload the page.';
  end if;
  if p_use_case_id is not null
     and not exists (select 1 from public.use_cases where id = p_use_case_id and not hidden) then
    raise exception 'That entry is no longer listed. Reload the page.';
  end if;
end;
$$;

-- The write limit. The caller's address is read from the request headers PostgREST passes in:
-- Cloudflare's cf-connecting-ip when present (Cloudflare sets it, so a caller cannot), otherwise the
-- first address in x-forwarded-for. Only a salted hash of it is stored. Callers whose address cannot
-- be read share one count. The lock makes concurrent writes count one after another.
create function private.extensions_page_limit(p_kind text)
  returns void
  language plpgsql volatile set search_path = ''
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_address text;
  v_hash text;
  v_recent integer;
begin
  v_address := coalesce(
    nullif(btrim(v_headers ->> 'cf-connecting-ip'), ''),
    nullif(btrim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), ''),
    'unknown');
  select private.extensions_page_hash(s.salt || v_address) into v_hash from private.extensions_page_salt s;

  perform pg_advisory_xact_lock(hashtextextended('extensions_page_writes', 0));
  delete from private.extensions_page_writes where created_at < now() - interval '1 day';

  select count(*) into v_recent from private.extensions_page_writes
   where caller_hash = v_hash and kind = p_kind and created_at > now() - interval '1 hour';
  if v_recent >= (case p_kind when 'support' then 120 else 20 end) then
    raise exception 'Too many changes from your network in the last hour. Try again later.';
  end if;

  if p_kind = 'content' then
    select count(*) into v_recent from private.extensions_page_writes
     where kind = 'content' and created_at > now() - interval '1 hour';
    if v_recent >= 300 then
      raise exception 'This page has had too many additions in the last hour. Try again later.';
    end if;
  end if;

  insert into private.extensions_page_writes (caller_hash, kind) values (v_hash, p_kind);
end;
$$;

-- Whether this request may change the entry: a library admin, or the entry's edit key.
create function private.extensions_page_may_edit(p_extension_id uuid, p_use_case_id uuid, p_edit_key text)
  returns boolean
  language sql stable set search_path = ''
as $$
  select coalesce(private.is_library_admin(), false)
      or (coalesce(p_edit_key, '') <> '' and exists (
            select 1 from private.extensions_page_secrets s
             where s.edit_key_hash = private.extensions_page_hash(p_edit_key)
               and (s.extension_id = p_extension_id or s.use_case_id = p_use_case_id)));
$$;

revoke execute on function private.extensions_page_text, private.extensions_page_link,
  private.extensions_page_email, private.extensions_page_status, private.extensions_page_trap,
  private.extensions_page_hash, private.extensions_page_new_key, private.extensions_page_target,
  private.extensions_page_limit, private.extensions_page_may_edit
  from public, anon, authenticated;

-- What visitors read --------------------------------------------------------------------------------
-- The views run as their owner (security_invoker off), so they can count the thumbs up without
-- showing who gave them; visitors may only select from them. security_barrier keeps a visitor's own
-- filters from being applied before the views leave out hidden rows.

create view public.extensions_shown with (security_invoker = false, security_barrier = true) as
select
  e.id, e.name, e.adds, e.field, e.status, e.contact, e.link, e.core_relation, e.author_name,
  e.created_at, e.updated_at,
  (select count(*) from public.supports s where s.extension_id = e.id)::integer as support_count,
  (select count(*) from public.comments c where c.extension_id = e.id and not c.hidden)::integer as comment_count,
  coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'title', u.title) order by u.created_at)
      from public.use_case_extensions l
      join public.use_cases u on u.id = l.use_case_id
     where l.extension_id = e.id and not u.hidden
  ), '[]'::jsonb) as use_cases
from public.extensions e
where not e.hidden;

create view public.use_cases_shown with (security_invoker = false, security_barrier = true) as
select
  u.id, u.title, u.goal, u.gap, u.field, u.author_name, u.created_at, u.updated_at,
  (select count(*) from public.supports s where s.use_case_id = u.id)::integer as support_count,
  (select count(*) from public.comments c where c.use_case_id = u.id and not c.hidden)::integer as comment_count,
  coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name) order by e.name)
      from public.use_case_extensions l
      join public.extensions e on e.id = l.extension_id
     where l.use_case_id = u.id and not e.hidden
  ), '[]'::jsonb) as extensions
from public.use_cases u
where not u.hidden;

create view public.comments_shown with (security_invoker = false, security_barrier = true) as
select c.id, c.extension_id, c.use_case_id, c.body, c.author_name, c.created_at, c.updated_at
from public.comments c
where not c.hidden
  and (c.extension_id is null or exists (select 1 from public.extensions e where e.id = c.extension_id and not e.hidden))
  and (c.use_case_id is null or exists (select 1 from public.use_cases u where u.id = c.use_case_id and not u.hidden));

revoke all on public.extensions_shown, public.use_cases_shown, public.comments_shown from public, anon, authenticated;
grant select on public.extensions_shown, public.use_cases_shown, public.comments_shown to anon, authenticated;

-- What visitors write -------------------------------------------------------------------------------
-- Each returns JSON. A refused write raises an exception whose message is shown to the visitor.

create function public.add_extension(
  p_name text,
  p_adds text,
  p_status text,
  p_author_name text,
  p_field text default null,
  p_contact text default null,
  p_link text default null,
  p_core_relation text default null,
  p_email text default null,
  p_company text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_name text;
  v_adds text;
  v_field text;
  v_status text;
  v_contact text;
  v_link text;
  v_relation text;
  v_author text;
  v_email text;
  v_key text := private.extensions_page_new_key();
  v_id uuid;
begin
  perform private.extensions_page_trap(p_company);
  v_name := private.extensions_page_text(p_name, 'Name', 120, true);
  v_adds := private.extensions_page_text(p_adds, 'What it adds', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_status := private.extensions_page_status(p_status);
  v_contact := private.extensions_page_text(p_contact, 'Who to talk to', 300, false);
  v_link := private.extensions_page_link(p_link);
  v_relation := private.extensions_page_text(p_core_relation, 'How it relates to the core', 2000, false);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  v_email := private.extensions_page_email(p_email);
  perform private.extensions_page_limit('content');

  insert into public.extensions (name, adds, field, status, contact, link, core_relation, author_name)
  values (v_name, v_adds, v_field, v_status, v_contact, v_link, v_relation, v_author)
  returning id into v_id;

  insert into private.extensions_page_secrets (extension_id, email, edit_key_hash)
  values (v_id, v_email, private.extensions_page_hash(v_key));

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

create function public.add_use_case(
  p_title text,
  p_goal text,
  p_gap text,
  p_author_name text,
  p_field text default null,
  p_extension_ids uuid[] default '{}',
  p_email text default null,
  p_company text default null
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
  v_key text := private.extensions_page_new_key();
  v_id uuid;
begin
  perform private.extensions_page_trap(p_company);
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
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  v_email := private.extensions_page_email(p_email);
  perform private.extensions_page_limit('content');

  insert into public.use_cases (title, goal, gap, field, author_name)
  values (v_title, v_goal, v_gap, v_field, v_author)
  returning id into v_id;

  insert into public.use_case_extensions (use_case_id, extension_id)
  select v_id, x from unnest(v_ids) as x;

  insert into private.extensions_page_secrets (use_case_id, email, edit_key_hash)
  values (v_id, v_email, private.extensions_page_hash(v_key));

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

-- Give (p_on true) or take back (p_on false) one browser's thumbs up. Returns the new count.
create function public.set_entry_support(
  p_voter uuid,
  p_on boolean,
  p_extension_id uuid default null,
  p_use_case_id uuid default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_voter is null or p_on is null then
    raise exception 'This thumbs up could not be saved.';
  end if;
  perform private.extensions_page_target(p_extension_id, p_use_case_id);
  perform private.extensions_page_limit('support');

  if p_extension_id is not null then
    if p_on then
      insert into public.supports (extension_id, voter) values (p_extension_id, p_voter) on conflict do nothing;
    else
      delete from public.supports where extension_id = p_extension_id and voter = p_voter;
    end if;
    select count(*) into v_count from public.supports where extension_id = p_extension_id;
  else
    if p_on then
      insert into public.supports (use_case_id, voter) values (p_use_case_id, p_voter) on conflict do nothing;
    else
      delete from public.supports where use_case_id = p_use_case_id and voter = p_voter;
    end if;
    select count(*) into v_count from public.supports where use_case_id = p_use_case_id;
  end if;

  return jsonb_build_object('supported', p_on, 'support_count', v_count);
end;
$$;

create function public.add_entry_comment(
  p_body text,
  p_author_name text,
  p_extension_id uuid default null,
  p_use_case_id uuid default null,
  p_company text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_body text;
  v_author text;
  v_id uuid;
begin
  perform private.extensions_page_trap(p_company);
  perform private.extensions_page_target(p_extension_id, p_use_case_id);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  v_body := private.extensions_page_text(p_body, 'Comment', 2000, true);
  perform private.extensions_page_limit('content');

  insert into public.comments (extension_id, use_case_id, body, author_name)
  values (p_extension_id, p_use_case_id, v_body, v_author)
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end;
$$;

-- Editing: by the browser that holds the entry's edit key, or by a library admin. The email
-- address given with an entry is not changed here.
create function public.edit_extension(
  p_id uuid,
  p_name text,
  p_adds text,
  p_status text,
  p_author_name text,
  p_field text default null,
  p_contact text default null,
  p_link text default null,
  p_core_relation text default null,
  p_edit_key text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_admin boolean := coalesce(private.is_library_admin(), false);
  v_hidden boolean;
  v_name text;
  v_adds text;
  v_field text;
  v_status text;
  v_contact text;
  v_link text;
  v_relation text;
  v_author text;
begin
  select hidden into v_hidden from public.extensions where id = p_id;
  if not found then
    raise exception 'That entry does not exist.';
  end if;
  if not private.extensions_page_may_edit(p_id, null, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  if v_hidden and not v_admin then
    raise exception 'That entry is no longer listed. Reload the page.';
  end if;
  v_name := private.extensions_page_text(p_name, 'Name', 120, true);
  v_adds := private.extensions_page_text(p_adds, 'What it adds', 2000, true);
  v_field := private.extensions_page_text(p_field, 'Field or domain', 120, false);
  v_status := private.extensions_page_status(p_status);
  v_contact := private.extensions_page_text(p_contact, 'Who to talk to', 300, false);
  v_link := private.extensions_page_link(p_link);
  v_relation := private.extensions_page_text(p_core_relation, 'How it relates to the core', 2000, false);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    perform private.extensions_page_limit('content');
  end if;

  update public.extensions
     set name = v_name, adds = v_adds, field = v_field, status = v_status, contact = v_contact,
         link = v_link, core_relation = v_relation, author_name = v_author, updated_at = now()
   where id = p_id;

  return jsonb_build_object('id', p_id);
end;
$$;

-- The use case's extension links become the ones given; links to hidden extensions are kept.
create function public.edit_use_case(
  p_id uuid,
  p_title text,
  p_goal text,
  p_gap text,
  p_author_name text,
  p_field text default null,
  p_extension_ids uuid[] default '{}',
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
begin
  select hidden into v_hidden from public.use_cases where id = p_id;
  if not found then
    raise exception 'That entry does not exist.';
  end if;
  if not private.extensions_page_may_edit(null, p_id, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
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
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    perform private.extensions_page_limit('content');
  end if;

  update public.use_cases
     set title = v_title, goal = v_goal, gap = v_gap, field = v_field, author_name = v_author, updated_at = now()
   where id = p_id;

  delete from public.use_case_extensions l
   where l.use_case_id = p_id
     and l.extension_id <> all (v_ids)
     and exists (select 1 from public.extensions e where e.id = l.extension_id and not e.hidden);
  insert into public.use_case_extensions (use_case_id, extension_id)
  select p_id, x from unnest(v_ids) as x
  on conflict do nothing;

  return jsonb_build_object('id', p_id);
end;
$$;

-- Admins only ---------------------------------------------------------------------------------------

-- Whether the signed-in account may moderate the page; false for everyone else.
create function public.can_moderate_entries()
  returns boolean
  language sql stable security definer set search_path = ''
as $$
  select coalesce(private.is_library_admin(), false);
$$;

create function public.edit_entry_comment(p_id uuid, p_body text, p_author_name text)
  returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_body text;
  v_author text;
begin
  if not coalesce(private.is_library_admin(), false) then
    raise exception 'Only library admins can edit comments.';
  end if;
  v_author := private.extensions_page_text(p_author_name, 'Name', 120, true);
  v_body := private.extensions_page_text(p_body, 'Comment', 2000, true);
  update public.comments set body = v_body, author_name = v_author, updated_at = now() where id = p_id;
  if not found then
    raise exception 'That comment does not exist.';
  end if;
  return jsonb_build_object('id', p_id);
end;
$$;

-- Hide (p_hidden true) or show again (p_hidden false) an extension, a use case, or a comment.
create function public.set_entry_hidden(p_kind text, p_id uuid, p_hidden boolean)
  returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not coalesce(private.is_library_admin(), false) then
    raise exception 'Only library admins can hide or show entries.';
  end if;
  if p_hidden is null then
    raise exception 'Say whether to hide or show.';
  end if;
  if p_kind = 'extension' then
    update public.extensions set hidden = p_hidden where id = p_id;
  elsif p_kind = 'use_case' then
    update public.use_cases set hidden = p_hidden where id = p_id;
  elsif p_kind = 'comment' then
    update public.comments set hidden = p_hidden where id = p_id;
  else
    raise exception 'Unknown kind of entry.';
  end if;
  if not found then
    raise exception 'That entry does not exist.';
  end if;
  return jsonb_build_object('id', p_id, 'hidden', p_hidden);
end;
$$;

-- What admins have hidden, so they can show it again.
create function public.hidden_entries()
  returns jsonb
  language plpgsql stable security definer set search_path = ''
as $$
begin
  if not coalesce(private.is_library_admin(), false) then
    raise exception 'Only library admins can see hidden entries.';
  end if;
  return jsonb_build_object(
    'extensions', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'author_name', e.author_name,
                                          'created_at', e.created_at) order by e.created_at desc)
        from public.extensions e where e.hidden), '[]'::jsonb),
    'use_cases', coalesce((
      select jsonb_agg(jsonb_build_object('id', u.id, 'title', u.title, 'author_name', u.author_name,
                                          'created_at', u.created_at) order by u.created_at desc)
        from public.use_cases u where u.hidden), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'body', c.body, 'author_name', c.author_name,
                                          'extension_id', c.extension_id, 'use_case_id', c.use_case_id,
                                          'created_at', c.created_at) order by c.created_at desc)
        from public.comments c where c.hidden), '[]'::jsonb)
  );
end;
$$;

-- Who may call what: every visitor may call these functions; each one checks the rest itself.
revoke execute on function public.add_extension, public.add_use_case, public.set_entry_support,
  public.add_entry_comment, public.edit_extension, public.edit_use_case, public.can_moderate_entries,
  public.edit_entry_comment, public.set_entry_hidden, public.hidden_entries
  from public, anon, authenticated;
grant execute on function public.add_extension, public.add_use_case, public.set_entry_support,
  public.add_entry_comment, public.edit_extension, public.edit_use_case, public.can_moderate_entries,
  public.edit_entry_comment, public.set_entry_hidden, public.hidden_entries
  to anon, authenticated;
