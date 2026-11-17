-- The extensions page (mira.science/extensions/): extensions to MIRA's core schema that people are
-- trying, and the use cases behind them. An extension can be one addition or a whole schema or lexicon:
-- besides its texts it holds up to 8 links and up to 100 rows, each row one thing it holds (a record
-- type, a link, a field, or something else) and how that thing stands against the core (it adds to it,
-- pairs with a core term, or differs from it). A use case picks the extensions that would cover it and
-- may pick rows of them. Anyone can add an extension or a use case, give a thumbs up, and comment,
-- without an account. Entries and comments show at once; library admins can hide them.
--
-- How it is kept safe:
-- - Visitors read only through three views (extensions_shown, use_cases_shown, and comments_shown).
--   They leave out hidden rows and private columns, and carry each entry's thumbs-up and comment counts.
-- - Visitors write only through the functions below. The tables have row-level security on, no
--   policies, and no grants for signed-out or signed-in visitors, so a visitor can never read, add,
--   change, or delete a row directly.
-- - Each write function checks what it is given: required fields, length limits (the tables hold the
--   same limits), links that start with https:// and hold no spaces, every link and row of an
--   extension, an empty spam-trap field, and how many writes the caller's network address made in the
--   last hour. The address is kept only as a salted hash, for about a day: rows older than a day are
--   deleted on each write and by an hourly pg_cron job, which this migration schedules (it fails if it
--   cannot).
-- - Email addresses and the hashes of the edit keys sit in a private table no visitor can read. The
--   browser that adds an entry is given its edit key once and keeps it; only that key, or a library
--   admin, can change the entry.
-- - Library admins (private.is_library_admin()) can edit, hide, and show again any entry or comment.
--
-- Write limits, counted per IPv4 address or per IPv6 /64 block. Adding or editing an extension counts
-- as one write however many links and rows it carries.
-- - 20 entries, comments, and edits an hour from one address, and 300 from all addresses together;
-- - 120 thumbs-up changes an hour from one address, and 600 from all addresses together.
-- The site-wide limits hold even if an address can be faked, and keep the tables from growing faster
-- than that.

-- pg_cron, for the hourly clean-up of the write-limit log at the end of this file. It comes first so
-- that, where pg_cron cannot be enabled, the migration fails before it creates anything.
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

-- Entries -------------------------------------------------------------------------------------------

create table public.extensions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> '' and char_length(name) <= 120),
  also_known_as text check (char_length(also_known_as) <= 200),             -- earlier or other names
  purpose text not null check (btrim(purpose) <> '' and char_length(purpose) <= 2000),  -- what it is for
  field text check (char_length(field) <= 120),
  status text not null check (status in ('idea', 'experimenting', 'in_use')),
  written_as text check (char_length(written_as) <= 200),                   -- e.g. LinkML or JSON-LD
  version text check (char_length(version) <= 200),                         -- the extension's own version
  compared_against text check (char_length(compared_against) <= 300),       -- the core version compared with
  core_relation text check (char_length(core_relation) <= 2000),            -- an overall note on the core
  contact text check (char_length(contact) <= 300),
  author_name text not null check (btrim(author_name) <> '' and char_length(author_name) <= 120),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- An extension's links, in the order given: a label and an https:// address each, at most 8.
create table public.extension_links (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid not null references public.extensions (id) on delete cascade,
  sort_order smallint not null check (sort_order between 1 and 8),
  label text not null check (btrim(label) <> '' and char_length(label) <= 80),
  url text not null check (char_length(url) <= 500 and url ~ '^https://[^[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$'),
  unique (extension_id, sort_order)
);

-- An extension's rows, in the order given, at most 100: one thing the extension holds each, its kind,
-- how it stands against the core, the core's term for it when there is one, and a note. Editing keeps
-- the ids of rows that stay, so a use case's pick of a row survives an edit.
create table public.extension_rows (
  id uuid primary key default gen_random_uuid(),
  extension_id uuid not null references public.extensions (id) on delete cascade,
  sort_order smallint not null check (sort_order between 1 and 100),
  name text not null check (btrim(name) <> '' and char_length(name) <= 120),
  kind text not null check (kind in ('record_type', 'link', 'field', 'other')),
  standing text not null check (standing in ('adds', 'pairs', 'differs')),
  core_term text check (char_length(core_term) <= 200),
  note text check (char_length(note) <= 600),
  unique (extension_id, id),
  unique (extension_id, sort_order) deferrable initially deferred   -- rows may swap places in one edit
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

-- Which rows of a picked extension a use case needs. The two foreign keys hold the rules: a row can be
-- picked only together with its extension, and only a row of that extension. Unpicking the extension
-- or removing the row removes the pick.
create table public.use_case_rows (
  use_case_id uuid not null,
  extension_id uuid not null,
  row_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (use_case_id, row_id),
  foreign key (use_case_id, extension_id) references public.use_case_extensions (use_case_id, extension_id) on delete cascade,
  foreign key (extension_id, row_id) references public.extension_rows (extension_id, id) on delete cascade
);

create index use_case_rows_row_idx on public.use_case_rows (extension_id, row_id);

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
  email text check (char_length(email) <= 254 and email ~ ('^[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
                                                            '@[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
                                                            '\.[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$')),
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
alter table public.extension_links enable row level security;
alter table public.extension_rows enable row level security;
alter table public.use_cases enable row level security;
alter table public.use_case_extensions enable row level security;
alter table public.use_case_rows enable row level security;
alter table public.supports enable row level security;
alter table public.comments enable row level security;
alter table private.extensions_page_secrets enable row level security;
alter table private.extensions_page_writes enable row level security;
alter table private.extensions_page_salt enable row level security;

revoke all on public.extensions, public.extension_links, public.extension_rows, public.use_cases,
  public.use_case_extensions, public.use_case_rows, public.supports, public.comments
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

-- A web address: https:// and no spaces. The spaces refused are the locale's own plus the Unicode ones
-- listed, such as the no-break space, so the check is the same whatever the database's locale. The
-- page refuses the same set.
create function private.extensions_page_link(p_value text, p_label text, p_required boolean)
  returns text
  language plpgsql stable set search_path = ''
as $$
declare
  v text := private.extensions_page_text(p_value, p_label, 500, p_required);
begin
  if v is null then
    return null;
  end if;
  if left(v, 8) <> 'https://' then
    raise exception '“%” must start with https://.', p_label;
  end if;
  if v !~ '^https://[^[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$' then
    raise exception '“%” must be a single web address without spaces.', p_label;
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
  if v is not null and v !~ ('^[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
                             '@[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
                             '\.[^@[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$') then
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

-- An extension's links as the form sends them: a JSON array of at most 8 objects, each with a label
-- and an address. Returns them checked, as {label, url, sort_order}. A message names the link by its
-- place in the list.
create function private.extensions_page_links(p_links jsonb)
  returns jsonb
  language plpgsql stable set search_path = ''
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_item jsonb;
  v_n integer;
  v_label text;
  v_url text;
begin
  if p_links is null or jsonb_typeof(p_links) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p_links) <> 'array' then
    raise exception '“Links” could not be read.';
  end if;
  if jsonb_array_length(p_links) > 8 then
    raise exception 'An extension can have at most 8 links. This one has %.', jsonb_array_length(p_links);
  end if;
  for v_item, v_n in select t.e, t.o from jsonb_array_elements(p_links) with ordinality as t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Link % could not be read.', v_n;
    end if;
    begin
      v_label := private.extensions_page_text(v_item ->> 'label', 'Label', 80, true);
      v_url := private.extensions_page_link(v_item ->> 'url', 'Address', true);
    exception when raise_exception then
      raise exception 'Link %: %', v_n, sqlerrm;
    end;
    v_out := v_out || jsonb_build_array(jsonb_build_object('label', v_label, 'url', v_url, 'sort_order', v_n));
  end loop;
  return v_out;
end;
$$;

-- An extension's rows as the form sends them: a JSON array of at most 100 objects, each with a name, a
-- kind, a standing, and optionally a core term, a note, and the id of a row it keeps. Returns them
-- checked, as {id, name, kind, standing, core_term, note, sort_order}. Whether a kept id belongs to the
-- extension is checked by edit_extension. A message names the row by its place in the list.
create function private.extensions_page_rows(p_rows jsonb)
  returns jsonb
  language plpgsql stable set search_path = ''
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_item jsonb;
  v_n integer;
  v_id text;
  v_seen text[] := '{}';
  v_name text;
  v_kind text;
  v_standing text;
  v_term text;
  v_note text;
begin
  if p_rows is null or jsonb_typeof(p_rows) = 'null' then
    return v_out;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception '“Rows” could not be read.';
  end if;
  if jsonb_array_length(p_rows) > 100 then
    raise exception 'An extension can hold at most 100 rows. This one has %.', jsonb_array_length(p_rows);
  end if;
  for v_item, v_n in select t.e, t.o from jsonb_array_elements(p_rows) with ordinality as t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Row % could not be read.', v_n;
    end if;
    v_id := nullif(v_item ->> 'id', '');
    if v_id is not null then
      if v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'Row % could not be read.', v_n;
      end if;
      v_id := lower(v_id);
      if v_id = any (v_seen) then
        raise exception 'Row % repeats an earlier row.', v_n;
      end if;
      v_seen := v_seen || v_id;
    end if;
    begin
      v_name := private.extensions_page_text(v_item ->> 'name', 'Name', 120, true);
      v_kind := v_item ->> 'kind';
      if v_kind is null or v_kind not in ('record_type', 'link', 'field', 'other') then
        raise exception '“Kind” must be Record type, Link, Field, or Other.';
      end if;
      v_standing := v_item ->> 'standing';
      if v_standing is null or v_standing not in ('adds', 'pairs', 'differs') then
        raise exception '“Against the core” must be Adds, Pairs with, or Differs from.';
      end if;
      v_term := private.extensions_page_text(v_item ->> 'core_term', 'Core term', 200, false);
      v_note := private.extensions_page_text(v_item ->> 'note', 'Note', 600, false);
    exception when raise_exception then
      raise exception 'Row %: %', v_n, sqlerrm;
    end;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_id, 'name', v_name, 'kind', v_kind,
               'standing', v_standing, 'core_term', v_term, 'note', v_note, 'sort_order', v_n));
  end loop;
  return v_out;
end;
$$;

-- The rows a use case picks: each one shown, and each one of an extension the use case also picks.
create function private.extensions_page_row_picks(p_row_ids uuid[], p_extension_ids uuid[])
  returns uuid[]
  language plpgsql stable set search_path = ''
as $$
declare
  v_rows uuid[] := array(select distinct x from unnest(coalesce(p_row_ids, '{}'::uuid[])) as x where x is not null);
begin
  if cardinality(v_rows) > 200 then
    raise exception 'Pick at most 200 rows.';
  end if;
  if exists (select 1 from unnest(v_rows) as x
              where not exists (select 1 from public.extension_rows r join public.extensions e on e.id = r.extension_id
                                 where r.id = x and not e.hidden)) then
    raise exception 'One of the rows you picked is no longer listed. Reload the page. Then try again.';
  end if;
  if exists (select 1 from unnest(v_rows) as x join public.extension_rows r on r.id = x
              where r.extension_id <> all (coalesce(p_extension_ids, '{}'::uuid[]))) then
    raise exception 'Tick a row''s extension before picking the row.';
  end if;
  return v_rows;
end;
$$;

-- The spam trap: a field people never see, so only a program fills it in.
create function private.extensions_page_trap(p_trap text)
  returns void
  language plpgsql immutable set search_path = ''
as $$
begin
  if coalesce(p_trap, '') <> '' then
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

-- Forgets write-limit rows older than a day. Called on each write and by the hourly pg_cron job
-- scheduled at the end of this file, so an address is kept for about a day even when nobody writes.
create function private.extensions_page_forget_writes()
  returns void
  language sql volatile set search_path = ''
as $$
  delete from private.extensions_page_writes where created_at < now() - interval '1 day';
$$;

-- The write limit. The caller's address is read from the request headers PostgREST passes in:
-- Cloudflare's cf-connecting-ip when present (Cloudflare sets it, so a caller cannot), otherwise the
-- first address in x-forwarded-for. An IPv4 caller is counted by its address; an IPv6 caller by its
-- /64 block, since one machine can take any address inside the block it is given. Only a salted hash
-- of that is stored. Callers whose address cannot be read share one count. The lock makes concurrent
-- writes count one after another.
create function private.extensions_page_limit(p_kind text)
  returns void
  language plpgsql volatile set search_path = ''
as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_address text;
  v_inet inet;
  v_caller text;
  v_hash text;
  v_recent integer;
begin
  v_address := coalesce(
    nullif(btrim(v_headers ->> 'cf-connecting-ip'), ''),
    nullif(btrim(split_part(v_headers ->> 'x-forwarded-for', ',', 1)), ''),
    'unknown');
  begin
    v_inet := v_address::inet;
  exception when invalid_text_representation then
    v_inet := null;
  end;
  if v_inet is null then
    v_caller := lower(left(v_address, 100));
  elsif family(v_inet) = 6 and not (v_inet <<= '::ffff:0:0/96'::inet) then
    v_caller := network(set_masklen(v_inet, 64))::text;
  else
    v_caller := host(v_inet);
  end if;
  select private.extensions_page_hash(s.salt || v_caller) into v_hash from private.extensions_page_salt s;

  perform pg_advisory_xact_lock(hashtextextended('extensions_page_writes', 0));
  perform private.extensions_page_forget_writes();

  select count(*) into v_recent from private.extensions_page_writes
   where caller_hash = v_hash and kind = p_kind and created_at > now() - interval '1 hour';
  if v_recent >= (case p_kind when 'support' then 120 else 20 end) then
    raise exception 'Too many changes from your network in the last hour. Try again later.';
  end if;

  select count(*) into v_recent from private.extensions_page_writes
   where kind = p_kind and created_at > now() - interval '1 hour';
  if p_kind = 'content' and v_recent >= 300 then
    raise exception 'This page has had too many additions in the last hour. Try again later.';
  end if;
  if p_kind = 'support' and v_recent >= 600 then
    raise exception 'This page has had too many thumbs up in the last hour. Try again later.';
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
  private.extensions_page_email, private.extensions_page_status, private.extensions_page_links,
  private.extensions_page_rows, private.extensions_page_row_picks, private.extensions_page_trap,
  private.extensions_page_hash, private.extensions_page_new_key, private.extensions_page_target,
  private.extensions_page_forget_writes, private.extensions_page_limit, private.extensions_page_may_edit
  from public, anon, authenticated;

-- What visitors read --------------------------------------------------------------------------------
-- The three views are owner-rights views on purpose (security_invoker off): they read the tables with
-- their owner's rights, so they can leave out hidden rows and count the thumbs up without showing who
-- gave them, while visitors have no rights on the tables at all. Supabase's security advisor lists
-- them as "Security Definer View"; that is expected. Do not turn security_invoker on: the views would
-- then read the tables with the visitor's own rights, so the lists would fail to load, and even with
-- table grants added they would come back empty, since the tables have no row-level policies.
-- Visitors may only select from the views. security_barrier keeps a visitor's own filters from being
-- applied before the views leave out hidden rows.
--
-- An extension's links and rows come with it, in their order; each row carries the shown use cases
-- that picked it. A use case's extensions carry the rows it picked of each. A hidden extension's links
-- and rows are left out with it.

create view public.extensions_shown with (security_invoker = false, security_barrier = true) as
select
  e.id, e.name, e.also_known_as, e.purpose, e.field, e.status, e.written_as, e.version,
  e.compared_against, e.core_relation, e.contact, e.author_name, e.created_at, e.updated_at,
  (select count(*) from public.supports s where s.extension_id = e.id)::integer as support_count,
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
               select jsonb_agg(jsonb_build_object('id', u.id, 'title', u.title) order by u.created_at)
                 from public.use_case_rows p
                 join public.use_cases u on u.id = p.use_case_id
                where p.row_id = r.id and not u.hidden), '[]'::jsonb))
           order by r.sort_order)
      from public.extension_rows r
     where r.extension_id = e.id
  ), '[]'::jsonb) as rows,
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
    select jsonb_agg(jsonb_build_object(
             'id', e.id, 'name', e.name,
             'rows', coalesce((
               select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) order by r.sort_order)
                 from public.use_case_rows p
                 join public.extension_rows r on r.id = p.row_id
                where p.use_case_id = u.id and p.extension_id = e.id), '[]'::jsonb))
           order by e.name)
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

-- Links and rows arrive as JSON arrays: p_links as [{label, url}], p_rows as
-- [{name, kind, standing, core_term, note}] (and, when editing, the id of each row that stays).
create function public.add_extension(
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
  perform private.extensions_page_limit('content');

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

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

-- p_row_ids: rows of the picked extensions that the use case needs.
create function public.add_use_case(
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
  perform private.extensions_page_limit('content');

  insert into public.use_cases (title, goal, gap, field, author_name)
  values (v_title, v_goal, v_gap, v_field, v_author)
  returning id into v_id;

  insert into public.use_case_extensions (use_case_id, extension_id)
  select v_id, x from unnest(v_ids) as x;

  insert into public.use_case_rows (use_case_id, extension_id, row_id)
  select v_id, r.extension_id, r.id from public.extension_rows r where r.id = any (v_rows);

  insert into private.extensions_page_secrets (use_case_id, email, edit_key_hash)
  values (v_id, v_email, private.extensions_page_hash(v_key));

  return jsonb_build_object('id', v_id, 'edit_key', v_key);
end;
$$;

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
  p_trap text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_body text;
  v_author text;
  v_id uuid;
begin
  perform private.extensions_page_trap(p_trap);
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

-- The links become the ones given. The rows become the ones given, in their order: a row sent with
-- its id keeps that id (so use cases that picked it keep their pick); a row sent without one is new;
-- a row not sent is removed, with every use case's pick of it.
create function public.edit_extension(
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
  p_links jsonb default '[]',
  p_rows jsonb default '[]',
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
begin
  -- The key comes first, so that without it a hidden entry and a missing one look the same.
  if not private.extensions_page_may_edit(p_id, null, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  select hidden into v_hidden from public.extensions where id = p_id;
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
  v_links := private.extensions_page_links(p_links);
  v_rows := private.extensions_page_rows(p_rows);
  select min(t.o) into v_stray
    from jsonb_array_elements(v_rows) with ordinality as t(e, o)
   where t.e ->> 'id' is not null
     and not exists (select 1 from public.extension_rows r
                      where r.id = (t.e ->> 'id')::uuid and r.extension_id = p_id);
  if v_stray is not null then
    raise exception 'Row % is no longer part of this extension. Reload the page. Then try again.', v_stray;
  end if;
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    perform private.extensions_page_limit('content');
  end if;

  update public.extensions
     set name = v_name, also_known_as = v_aka, purpose = v_purpose, field = v_field, status = v_status,
         written_as = v_written, version = v_version, compared_against = v_compared,
         core_relation = v_relation, contact = v_contact, author_name = v_author, updated_at = now()
   where id = p_id;

  delete from public.extension_links where extension_id = p_id;
  insert into public.extension_links (extension_id, sort_order, label, url)
  select p_id, x.sort_order, x.label, x.url
    from jsonb_to_recordset(v_links) as x(label text, url text, sort_order smallint);

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

  return jsonb_build_object('id', p_id);
end;
$$;

-- The use case's extension and row picks become the ones given; picks of hidden extensions are kept.
create function public.edit_use_case(
  p_id uuid,
  p_title text,
  p_goal text,
  p_gap text,
  p_author_name text,
  p_field text default null,
  p_extension_ids uuid[] default '{}',
  p_row_ids uuid[] default '{}',
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
begin
  -- The key comes first, so that without it a hidden entry and a missing one look the same.
  if not private.extensions_page_may_edit(null, p_id, p_edit_key) then
    raise exception 'This browser cannot edit that entry.';
  end if;
  select hidden into v_hidden from public.use_cases where id = p_id;
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
  v_rows := private.extensions_page_row_picks(p_row_ids, v_ids);
  v_author := private.extensions_page_text(p_author_name, 'Your name', 120, true);
  if not v_admin then
    perform private.extensions_page_limit('content');
  end if;

  update public.use_cases
     set title = v_title, goal = v_goal, gap = v_gap, field = v_field, author_name = v_author, updated_at = now()
   where id = p_id;

  -- Unpicking an extension also drops the use case's picks of its rows (foreign key, on delete cascade).
  delete from public.use_case_extensions l
   where l.use_case_id = p_id
     and l.extension_id <> all (v_ids)
     and exists (select 1 from public.extensions e where e.id = l.extension_id and not e.hidden);
  insert into public.use_case_extensions (use_case_id, extension_id)
  select p_id, x from unnest(v_ids) as x
  on conflict do nothing;

  delete from public.use_case_rows p
   where p.use_case_id = p_id
     and p.row_id <> all (v_rows)
     and exists (select 1 from public.extensions e where e.id = p.extension_id and not e.hidden);
  insert into public.use_case_rows (use_case_id, extension_id, row_id)
  select p_id, r.extension_id, r.id from public.extension_rows r where r.id = any (v_rows)
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

-- The hourly clean-up --------------------------------------------------------------------------------
-- The job deletes write-limit rows older than a day, so an address is kept for about a day even when
-- nobody writes. If the job is not there afterwards, this migration fails instead of leaving the
-- addresses kept for longer than the privacy page says.

select cron.schedule('extensions-page-forget-writes', '0 * * * *',
                     'select private.extensions_page_forget_writes()');

do $$
begin
  if not exists (select 1 from cron.job
                  where jobname = 'extensions-page-forget-writes'
                    and schedule = '0 * * * *'
                    and command = 'select private.extensions_page_forget_writes()'
                    and active) then
    raise exception 'The hourly job that forgets old write-limit rows was not scheduled.';
  end if;
end;
$$;
