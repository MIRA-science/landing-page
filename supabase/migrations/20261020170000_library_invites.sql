-- Invitations. Jonathan approves each member by email; the library makes the account and a personal link
-- that he sends from his own email. The link lets its holder choose a password and lasts longer than
-- Supabase's own sign-in links (at most a day). Only the two library functions read or write this
-- table: no policies, and no grants for signed-in or signed-out visitors.

create table public.invites (
  token_hash text primary key,                -- SHA-256 of the link's token; the token itself is never stored
  user_id uuid not null references auth.users (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);

create index invites_user_idx on public.invites (user_id);

alter table public.invites enable row level security;
revoke all on public.invites from public, anon, authenticated;
grant all on public.invites to service_role;

-- A Gmail address a member asked to sign in with is a second account standing for the same person.
alter table public.members add column alias_of uuid references public.members (user_id) on delete cascade;
create index members_alias_of_idx on public.members (alias_of);
