-- Only the person who added a file, or an admin, can edit its details; only the person who made a bundle,
-- or an admin, can rename it or change its date. Any member can still add files, including to any bundle.

drop policy "Members can edit resources" on public.resources;

create policy "Uploaders and admins can edit resources"
  on public.resources for update to authenticated
  using ((select private.is_member()) and (uploaded_by = (select auth.uid()) or (select private.is_library_admin())))
  with check ((select private.is_member()) and (uploaded_by = (select auth.uid()) or (select private.is_library_admin())));

drop policy "Members can edit bundles" on public.bundles;

create policy "Creators and admins can edit bundles"
  on public.bundles for update to authenticated
  using ((select private.is_member()) and (created_by = (select auth.uid()) or (select private.is_library_admin())))
  with check ((select private.is_member()) and (created_by = (select auth.uid()) or (select private.is_library_admin())));
