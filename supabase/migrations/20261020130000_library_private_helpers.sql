-- Keep the access-check helpers out of the public API. The policies keep using them
-- (they refer to the functions themselves, not their names), but they are no longer
-- callable as /rest/v1/rpc endpoints.

create schema if not exists private;
grant usage on schema private to authenticated;

alter function public.is_member() set schema private;
alter function public.is_library_admin() set schema private;
