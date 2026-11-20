-- Members' email addresses, and the form for people who want to join MIRA (and its Slack).
--
-- Email addresses:
-- - A member's email address is visible to admins only. Members still see each other's names and who
--   is an admin, which is what the library shows. Admins read email addresses through the
--   library-admin function, which reads with the service role and is not affected.
--
-- The interest form:
-- - Anyone can say they would like to join: a name, an email address, what they would like to do with
--   MIRA, and optionally an affiliation and a link. It goes through one function, with the extensions
--   page's checks: the spam trap, length limits, and the write limit (it counts as one unit of the
--   page's "content" writes).
-- - What people send is kept in a private table no visitor can read. Admins list it and mark each one
--   invited or declined through two functions; inviting itself stays the library's invite flow.

-- Email addresses --------------------------------------------------------------------------------

revoke select on public.members from authenticated;
grant select (user_id, display_name, is_admin, alias_of, added_at) on public.members to authenticated;

-- The interest form --------------------------------------------------------------------------------

create table private.interest_registrations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> '' and char_length(name) <= 120),
  email text not null check (char_length(email) <= 254),
  affiliation text check (char_length(affiliation) <= 200),
  link text check (char_length(link) <= 500),               -- a homepage, ORCID, or profile
  interest text not null check (btrim(interest) <> '' and char_length(interest) <= 2000),
  status text not null default 'new' check (status in ('new', 'invited', 'declined')),
  admin_note text check (char_length(admin_note) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index interest_registrations_listing_idx on private.interest_registrations (status, created_at desc);

alter table private.interest_registrations enable row level security;
revoke all on private.interest_registrations from public, anon, authenticated;

create function public.register_interest(
  p_name text,
  p_email text,
  p_interest text,
  p_affiliation text default null,
  p_link text default null,
  p_trap text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_name text;
  v_email text;
  v_interest text;
  v_affiliation text;
  v_link text;
begin
  perform private.extensions_page_trap(p_trap);
  v_name := private.extensions_page_text(p_name, 'Your name', 120, true);
  v_email := private.extensions_page_email(p_email);
  if v_email is null then
    raise exception '“Your email” is required.';
  end if;
  v_interest := private.extensions_page_text(p_interest, 'What you would like to do with MIRA', 2000, true);
  v_affiliation := private.extensions_page_text(p_affiliation, 'Affiliation', 200, false);
  v_link := private.extensions_page_link(p_link, 'Link', false);
  perform private.extensions_page_limit('content', 1);

  insert into private.interest_registrations (name, email, affiliation, link, interest)
  values (v_name, v_email, v_affiliation, v_link, v_interest);

  return jsonb_build_object('registered', true);
end;
$$;

-- What people sent, newest first, for admins only.
create function public.interest_registrations()
  returns jsonb
  language plpgsql stable security definer set search_path = ''
as $$
begin
  if not coalesce(private.is_library_admin(), false) then
    raise exception 'Only library admins can see who asked to join.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'email', r.email,
                                        'affiliation', r.affiliation, 'link', r.link, 'interest', r.interest,
                                        'status', r.status, 'admin_note', r.admin_note,
                                        'created_at', r.created_at, 'updated_at', r.updated_at)
                     order by r.created_at desc, r.id desc)
      from private.interest_registrations r), '[]'::jsonb);
end;
$$;

-- Marks one as new, invited, or declined, with an optional note for the other admins.
create function public.set_interest_status(p_id uuid, p_status text, p_note text default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not coalesce(private.is_library_admin(), false) then
    raise exception 'Only library admins can do that.';
  end if;
  if p_status is null or p_status not in ('new', 'invited', 'declined') then
    raise exception 'Choose new, invited, or declined.';
  end if;
  update private.interest_registrations
     set status = p_status, admin_note = private.extensions_page_text(p_note, 'Note', 2000, false),
         updated_at = now()
   where id = p_id;
  if not found then
    raise exception 'That registration does not exist.';
  end if;
  return jsonb_build_object('id', p_id, 'status', p_status);
end;
$$;

revoke execute on function public.register_interest, public.interest_registrations, public.set_interest_status
  from public, anon, authenticated;
grant execute on function public.register_interest to anon, authenticated;
grant execute on function public.interest_registrations, public.set_interest_status to authenticated;
