-- Rollback-only Salahly authorization checks; no pgTAP or psql commands.
-- First install 202610160001_salahly_foundation.sql, then run this WHOLE file
-- as postgres in a test project's Supabase SQL Editor. Never run selections
-- out of order or replace the final ROLLBACK with COMMIT.
--
-- Creates exactly two synthetic auth users, their triggered profiles/welcomes,
-- and temporary catalog/notification fixtures using random UUIDs. No existing
-- user/catalog rows are modified. All database fixture changes roll back.
-- An unexpected result raises an exception and aborts the transaction. Success
-- emits the final 'PASS: all Salahly foundation checks passed' notice before
-- ROLLBACK. If the editor stops on an error, run ROLLBACK to release the aborted
-- transaction; a generic 'query succeeded' without that notice is not a pass.
--
-- JWT GUCs + SET LOCAL ROLE simulate PostgREST authorization, not Auth login.
-- These fixtures have no usable password/identities and cannot test signup
-- emails, token validation, HTTP configuration, migration reruns/backfill,
-- concurrency, or Realtime/Storage. External effects from unrelated custom
-- auth hooks/webhooks are not covered by database rollback; use a test project.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

do $fixtures$
declare
  user_a uuid := pg_catalog.gen_random_uuid();
  user_b uuid := pg_catalog.gen_random_uuid();
  active_category uuid := pg_catalog.gen_random_uuid();
  inactive_category uuid := pg_catalog.gen_random_uuid();
  relation_name text;
  routine_name text;
begin
  if current_user <> 'postgres' then
    raise exception 'Run the entire foundation test as postgres in the Supabase SQL Editor.';
  end if;

  -- Check exact ACLs, not just RLS behavior. Otherwise a missing INSERT policy
  -- could conceal an accidental INSERT grant, or a column grant could survive
  -- a table-level REVOKE. has_*_privilege also accounts for PUBLIC/inheritance.
  foreach relation_name in array array[
    'public.profiles', 'public.service_categories', 'public.notifications'
  ] loop
    if not pg_catalog.has_table_privilege('authenticated', relation_name, 'SELECT')
      or pg_catalog.has_table_privilege(
        'authenticated', relation_name, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
      )
      or pg_catalog.has_any_column_privilege('authenticated', relation_name, 'INSERT,REFERENCES') then
      raise exception 'FAIL: unexpected authenticated table/column privileges on %', relation_name;
    end if;

    if pg_catalog.has_table_privilege(
      'anon', relation_name, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    ) or pg_catalog.has_any_column_privilege('anon', relation_name, 'SELECT,INSERT,UPDATE,REFERENCES') then
      raise exception 'FAIL: anon has privileges on %', relation_name;
    end if;

    if not (
      pg_catalog.has_table_privilege('service_role', relation_name, 'SELECT')
      and pg_catalog.has_table_privilege('service_role', relation_name, 'INSERT')
      and pg_catalog.has_table_privilege('service_role', relation_name, 'UPDATE')
      and pg_catalog.has_table_privilege('service_role', relation_name, 'DELETE')
    ) or pg_catalog.has_table_privilege('service_role', relation_name, 'TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'FAIL: service_role must have CRUD only on %', relation_name;
    end if;
  end loop;

  if exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid in (
      'public.profiles'::pg_catalog.regclass,
      'public.service_categories'::pg_catalog.regclass,
      'public.notifications'::pg_catalog.regclass
    )
      and attribute.attnum > 0 and not attribute.attisdropped
      and pg_catalog.has_column_privilege(
        'authenticated', attribute.attrelid, attribute.attnum, 'UPDATE'
      ) is distinct from (
        (attribute.attrelid = 'public.profiles'::pg_catalog.regclass
          and attribute.attname in ('full_name', 'phone', 'city'))
        or (attribute.attrelid = 'public.notifications'::pg_catalog.regclass
          and attribute.attname = 'read_at')
      )
  ) then
    raise exception 'FAIL: authenticated UPDATE grants differ from the four permitted columns.';
  end if;

  if exists (
    select 1 from pg_catalog.pg_class
    where oid in (
      'public.profiles'::pg_catalog.regclass,
      'public.service_categories'::pg_catalog.regclass,
      'public.notifications'::pg_catalog.regclass
    ) and not relrowsecurity
  ) then
    raise exception 'FAIL: RLS must be enabled on all three foundation tables.';
  end if;

  foreach routine_name in array array[
    'public.salahly_touch_profile_updated_at()',
    'public.salahly_handle_auth_user_created()'
  ] loop
    if pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      or pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE') then
      raise exception 'FAIL: trigger function is callable by an API role: %', routine_name;
    end if;
  end loop;

  perform pg_catalog.set_config('salahly_test.user_a', user_a::text, true);
  perform pg_catalog.set_config('salahly_test.user_b', user_b::text, true);
  perform pg_catalog.set_config('salahly_test.active_category', active_category::text, true);
  perform pg_catalog.set_config('salahly_test.inactive_category', inactive_category::text, true);

  -- Real auth table inserts exercise the signup trigger. An admin payload must
  -- become customer; the other user's valid provider role must be retained.
  insert into auth.users (
    id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) values
    (
      user_a, 'authenticated', 'authenticated',
      'salahly-rls-' || user_a::text || '@example.invalid',
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"  RLS Customer  ","role":"admin","is_admin":true}'::jsonb,
      pg_catalog.now(), pg_catalog.now()
    ),
    (
      user_b, 'authenticated', 'authenticated',
      'salahly-rls-' || user_b::text || '@example.invalid',
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name":"x","role":"provider"}'::jsonb,
      pg_catalog.now(), pg_catalog.now()
    );

  if not exists (
    select 1 from public.profiles
    where id = user_a and role = 'customer' and full_name = 'RLS Customer'
  ) or not exists (
    select 1 from public.profiles
    where id = user_b and role = 'provider' and full_name = 'Salahly User'
  ) then
    raise exception 'FAIL: signup role whitelist, trimmed name, or safe name fallback failed.';
  end if;

  if (select pg_catalog.count(*) from public.notifications where user_id = user_a) <> 1
    or (select pg_catalog.count(*) from public.notifications where user_id = user_b) <> 1
    or exists (
      select 1 from public.notifications
      where user_id in (user_a, user_b)
        and (
          pg_catalog.btrim(title_en) = '' or pg_catalog.btrim(title_ar) = ''
          or pg_catalog.btrim(body_en) = '' or pg_catalog.btrim(body_ar) = ''
          or title_en = title_ar or body_en = body_ar or read_at is not null
        )
    ) then
    raise exception 'FAIL: signup must create exactly one unread bilingual welcome per user.';
  end if;

  -- Simulate later Auth metadata changes as postgres. They must not overwrite
  -- an existing profile's role/name or send another welcome notification.
  update auth.users
  set raw_user_meta_data = pg_catalog.jsonb_build_object(
    'full_name', 'Changed auth metadata',
    'role', case when id = user_a then 'provider' else 'admin' end
  )
  where id in (user_a, user_b);

  if not exists (
    select 1 from public.profiles
    where id = user_a and role = 'customer' and full_name = 'RLS Customer'
  ) or not exists (
    select 1 from public.profiles
    where id = user_b and role = 'provider' and full_name = 'Salahly User'
  ) or (select pg_catalog.count(*) from public.notifications where user_id in (user_a, user_b)) <> 2 then
    raise exception 'FAIL: later Auth metadata changes synchronized a profile or created a welcome.';
  end if;

  -- Independent catalog fixtures avoid assuming existing seed rows are still
  -- active. They do not change any administrator-maintained catalog content.
  insert into public.service_categories (
    id, slug, name_en, name_ar, description_en, description_ar, icon_key, is_active
  ) values
    (
      active_category, 'rls_active_' || active_category::text,
      'RLS Active Fixture', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631',
      'Rollback-only active fixture.', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631',
      'rls_active_' || active_category::text, true
    ),
    (
      inactive_category, 'rls_inactive_' || inactive_category::text,
      'RLS Inactive Fixture', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631',
      'Rollback-only inactive fixture.', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631',
      'rls_inactive_' || inactive_category::text, false
    );

  raise notice 'PASS: exact ACLs, RLS enablement, signup provisioning, and metadata isolation.';
end;
$fixtures$;

-- Set both current and legacy claim formats used by Supabase auth.uid().
-- Changing GUCs alone is not an RLS test while still running as postgres.
select
  pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('salahly_test.user_a'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('salahly_test.user_a'), 'role', 'authenticated'
  )::text, true);
set local role authenticated;

do $customer$
declare
  own_id uuid := pg_catalog.current_setting('salahly_test.user_a')::uuid;
  other_id uuid := pg_catalog.current_setting('salahly_test.user_b')::uuid;
  own_notification_id uuid;
  previous_updated_at timestamptz;
  previous_created_at timestamptz;
  affected integer;
  statement_text text;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from own_id then
    raise exception 'FAIL: customer test is not executing with the expected authenticated identity.';
  end if;

  if (select pg_catalog.count(*) from public.profiles) <> 1
    or not exists (select 1 from public.profiles where id = own_id)
    or exists (select 1 from public.profiles where id = other_id) then
    raise exception 'FAIL: customer must see exactly their own profile, never another user.';
  end if;

  if (select pg_catalog.count(*) from public.notifications) <> 1
    or not exists (select 1 from public.notifications where user_id = own_id)
    or exists (select 1 from public.notifications where user_id = other_id) then
    raise exception 'FAIL: customer must see only their own welcome notification.';
  end if;

  if not exists (
    select 1 from public.service_categories
    where id = pg_catalog.current_setting('salahly_test.active_category')::uuid
  ) or exists (
    select 1 from public.service_categories
    where id = pg_catalog.current_setting('salahly_test.inactive_category')::uuid
  ) or exists (select 1 from public.service_categories where not is_active) then
    raise exception 'FAIL: authenticated catalog reads must include active and hide inactive rows.';
  end if;

  select updated_at, created_at into previous_updated_at, previous_created_at
  from public.profiles where id = own_id;

  update public.profiles
  set full_name = 'RLS Customer Updated', phone = '+201234567890', city = 'Cairo'
  where id = own_id;
  get diagnostics affected = row_count;
  if affected <> 1 or not exists (
    select 1 from public.profiles
    where id = own_id and full_name = 'RLS Customer Updated'
      and phone = '+201234567890' and city = 'Cairo' and role = 'customer'
      and created_at = previous_created_at and updated_at > previous_updated_at
  ) then
    raise exception 'FAIL: allowed profile update or database-managed updated_at failed.';
  end if;

  -- Exercise the inbox's ordered read and id-scoped read_at update shape.
  select id into own_notification_id from public.notifications
  where user_id = own_id order by created_at desc limit 1;
  update public.notifications set read_at = pg_catalog.now()
  where id = own_notification_id and user_id = own_id;
  get diagnostics affected = row_count;
  if affected <> 1 or not exists (
    select 1 from public.notifications where user_id = own_id and read_at = pg_catalog.now()
  ) then
    raise exception 'FAIL: customer could not mark their own notification read.';
  end if;

  update public.profiles set full_name = 'Cross-user write' where id = other_id;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL: cross-user profile UPDATE must affect zero rows, got %', affected;
  end if;

  update public.notifications set read_at = pg_catalog.now() where user_id = other_id;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL: cross-user notification UPDATE must affect zero rows, got %', affected;
  end if;

  -- These must fail with insufficient_privilege, not merely affect zero rows.
  -- A different exception is NOT swallowed. Every write targets fixtures only.
  foreach statement_text in array array[
    $sql$update public.profiles set role = 'provider' where id = auth.uid()$sql$,
    $sql$update public.profiles set created_at = pg_catalog.now() where id = auth.uid()$sql$,
    $sql$update public.profiles set updated_at = pg_catalog.now() where id = auth.uid()$sql$,
    $sql$insert into public.profiles (id, full_name, role) values (auth.uid(), 'Forged Profile', 'customer')$sql$,
    $sql$delete from public.profiles where id = auth.uid()$sql$,
    $sql$insert into public.service_categories (slug, name_en, name_ar, description_en, description_ar, icon_key) values ('rls_forged_' || auth.uid()::text, 'Forged', 'Forged', 'Forged', 'Forged', 'plumbing')$sql$,
    $sql$update public.service_categories set name_en = 'Forged' where id = pg_catalog.current_setting('salahly_test.active_category')::uuid$sql$,
    $sql$delete from public.service_categories where id = pg_catalog.current_setting('salahly_test.active_category')::uuid$sql$,
    $sql$insert into public.notifications (user_id, title_en, title_ar, body_en, body_ar) values (auth.uid(), 'Forged', 'Forged', 'Forged', 'Forged')$sql$,
    $sql$delete from public.notifications where user_id = auth.uid()$sql$,
    $sql$update public.notifications set title_en = 'Forged' where user_id = auth.uid()$sql$,
    $sql$update public.notifications set user_id = pg_catalog.current_setting('salahly_test.user_b')::uuid where user_id = auth.uid()$sql$
  ] loop
    begin
      execute statement_text;
      raise exception 'FAIL: forbidden statement was accepted: %', statement_text;
    exception when insufficient_privilege then
      raise notice 'PASS (permission denied): %', statement_text;
    end;
  end loop;

  -- Allowed UPDATE columns still enforce storage constraints. The profile
  -- timestamp trigger's changes also roll back with each rejected statement.
  foreach statement_text in array array[
    $sql$update public.profiles set full_name = 'x' where id = auth.uid()$sql$,
    $sql$update public.profiles set full_name = ' Untrimmed ' where id = auth.uid()$sql$,
    $sql$update public.profiles set full_name = pg_catalog.repeat('x', 81) where id = auth.uid()$sql$,
    $sql$update public.profiles set phone = pg_catalog.repeat('1', 33) where id = auth.uid()$sql$,
    $sql$update public.profiles set city = pg_catalog.repeat('x', 101) where id = auth.uid()$sql$
  ] loop
    begin
      execute statement_text;
      raise exception 'FAIL: invalid profile data was accepted: %', statement_text;
    exception when check_violation then
      raise notice 'PASS (constraint rejected): %', statement_text;
    end;
  end loop;

  raise notice 'PASS: customer ownership, permitted updates, forbidden writes, and profile constraints.';
end;
$customer$;

-- Repeat isolation in the other direction. A provider has no extra access to
-- customer profiles/notifications in this foundation milestone.
set local role postgres;
select
  pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('salahly_test.user_b'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('salahly_test.user_b'), 'role', 'authenticated'
  )::text, true);
set local role authenticated;

do $provider$
declare
  own_id uuid := pg_catalog.current_setting('salahly_test.user_b')::uuid;
  other_id uuid := pg_catalog.current_setting('salahly_test.user_a')::uuid;
  affected integer;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from own_id then
    raise exception 'FAIL: provider test is not executing with the expected authenticated identity.';
  end if;

  if (select pg_catalog.count(*) from public.profiles) <> 1
    or not exists (select 1 from public.profiles where id = own_id and role = 'provider')
    or exists (select 1 from public.profiles where id = other_id)
    or (select pg_catalog.count(*) from public.notifications) <> 1
    or not exists (select 1 from public.notifications where user_id = own_id and read_at is null)
    or exists (select 1 from public.notifications where user_id = other_id) then
    raise exception 'FAIL: provider isolation or the earlier zero-row notification write failed.';
  end if;

  update public.profiles
  set full_name = 'RLS Provider Updated', phone = null, city = null
  where id = own_id;
  get diagnostics affected = row_count;
  if affected <> 1 or not exists (
    select 1 from public.profiles
    where id = own_id and full_name = 'RLS Provider Updated' and role = 'provider'
      and phone is null and city is null
  ) then
    raise exception 'FAIL: provider cannot update their own profile with nullable contact fields.';
  end if;

  update public.notifications set read_at = pg_catalog.now() where user_id = own_id;
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'FAIL: provider cannot mark their own notification read.';
  end if;

  update public.profiles set city = 'Cross-user write' where id = other_id;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL: provider modified another profile.';
  end if;

  update public.notifications set read_at = null where user_id = other_id;
  get diagnostics affected = row_count;
  if affected <> 0 then
    raise exception 'FAIL: provider modified another notification.';
  end if;

  raise notice 'PASS: provider own updates and symmetric cross-user isolation.';
end;
$provider$;

-- Even an authenticated DB role with no sub claim cannot see private rows.
set local role postgres;
select
  pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;

do $missing_identity$
begin
  if auth.uid() is not null
    or exists (select 1 from public.profiles)
    or exists (select 1 from public.notifications) then
    raise exception 'FAIL: missing identity must not reveal any private rows.';
  end if;
  raise notice 'PASS: missing authenticated identity exposes no private rows.';
end;
$missing_identity$;

-- Anonymous reads must be privilege errors, not just empty RLS results.
set local role postgres;
select
  pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;

do $anonymous$
declare
  statement_text text;
begin
  if current_user <> 'anon' then
    raise exception 'FAIL: anonymous checks are not executing as anon.';
  end if;
  foreach statement_text in array array[
    'select * from public.profiles',
    'select * from public.service_categories',
    'select * from public.notifications'
  ] loop
    begin
      execute statement_text;
      raise exception 'FAIL: anonymous read was accepted: %', statement_text;
    exception when insufficient_privilege then
      raise notice 'PASS (anonymous read denied): %', statement_text;
    end;
  end loop;
end;
$anonymous$;

-- Trusted service-role work is deliberately different from client access.
-- This is only SET ROLE inside postgres's transaction, never an exposed key.
set local role postgres;
select
  pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;

do $trusted_service$
declare
  fixture_notification uuid;
  affected integer;
begin
  if current_user <> 'service_role'
    or (select pg_catalog.count(*) from public.profiles where id in (
      pg_catalog.current_setting('salahly_test.user_a')::uuid,
      pg_catalog.current_setting('salahly_test.user_b')::uuid
    )) <> 2
    or not exists (
      select 1 from public.service_categories
      where id = pg_catalog.current_setting('salahly_test.inactive_category')::uuid
    ) then
    raise exception 'FAIL: trusted service_role cannot access foundation fixtures across RLS.';
  end if;

  insert into public.notifications (user_id, title_en, title_ar, body_en, body_ar)
  values (
    pg_catalog.current_setting('salahly_test.user_b')::uuid,
    'Trusted fixture', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631',
    'Rollback-only trusted fixture.', U&'\062A\0635\0646\064A\0641 \0644\0644\0627\062E\062A\0628\0627\0631'
  ) returning id into fixture_notification;

  update public.notifications set title_en = 'Trusted update' where id = fixture_notification;
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'FAIL: trusted service_role cannot update notification content.';
  end if;

  delete from public.notifications where id = fixture_notification;
  get diagnostics affected = row_count;
  if affected <> 1 then
    raise exception 'FAIL: trusted service_role cannot delete its notification fixture.';
  end if;

  raise notice 'PASS: trusted service_role read/insert/update/delete works without client privileges.';
end;
$trusted_service$;

set local role postgres;
do $complete$
begin
  if (select pg_catalog.count(*) from public.notifications where user_id in (
    pg_catalog.current_setting('salahly_test.user_a')::uuid,
    pg_catalog.current_setting('salahly_test.user_b')::uuid
  ) and read_at is not null) <> 2 then
    raise exception 'FAIL: fixture welcomes or their permitted read states were changed unexpectedly.';
  end if;
  raise notice 'PASS: all Salahly foundation checks passed; rolling back every fixture now.';
end;
$complete$;

rollback;
