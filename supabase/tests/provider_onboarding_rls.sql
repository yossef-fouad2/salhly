-- Rollback-only M5 authorization/Storage SQL checks. Install foundation and
-- 202610180001_provider_onboarding.sql, then run this WHOLE file as postgres in
-- a TEST Supabase project's SQL Editor. No pgTAP, psql commands, or keys needed.
-- Never replace the final ROLLBACK with COMMIT. On error, ROLLBACK the aborted
-- transaction before continuing; the final PASS notice is required for success.
--
-- Synthetic users, catalog rows, Storage metadata, broad adversarial policies,
-- and temporary test helpers all roll back. No pre-existing user/catalog rows
-- are changed. Broad Storage ACLs/policies are intentional rollback-only probes
-- proving that restrictive guards, not accidentally missing grants, protect M5.
-- Auth hooks/webhooks can have effects outside SQL rollback: use a test project.
--
-- SET ROLE + JWT GUCs simulate authorization, not signed JWT validation. These
-- tests do NOT upload/download bytes, exercise HTTP/Storage SDK permission
-- probes, signed URLs, size sniffing, or concurrent sessions. Metadata fixtures
-- with invalid sizes/MIME deliberately bypass the real Storage upload service.

begin;
set local search_path = '';
set local standard_conforming_strings = on;

create temporary table provider_test_scope (unused boolean) on commit drop;
create function pg_temp.provider_assert(p_condition boolean, p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  if p_condition is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'PASS: %', p_label;
end;
$function$;

create function pg_temp.provider_expect_error(p_sql text, p_state text, p_message text default null)
returns void language plpgsql security invoker set search_path = ''
as $function$
declare
  actual_state text;
  actual_message text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics actual_state = returned_sqlstate, actual_message = message_text;
  end;
  if actual_state is null or actual_state <> all(pg_catalog.string_to_array(p_state, ','))
    or (p_message is not null and actual_message is distinct from p_message) then
    raise exception 'FAIL: expected % / %, got % / %; SQL: %',
      p_state, p_message, actual_state, actual_message, p_sql;
  end if;
  raise notice 'PASS (expected error): % / %', actual_state, actual_message;
end;
$function$;

create function pg_temp.provider_path(p_user_id uuid, p_suffix text default '.jpg')
returns text language sql volatile security invoker set search_path = ''
as $function$
  select p_user_id::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '') || p_suffix;
$function$;
do $temp_grants$
begin
  execute pg_catalog.format('grant usage on schema %I to authenticated, anon, service_role',
    (select nspname from pg_catalog.pg_namespace where oid = pg_catalog.pg_my_temp_schema()));
end;
$temp_grants$;
grant execute on function pg_temp.provider_assert(boolean, text),
  pg_temp.provider_expect_error(text, text, text), pg_temp.provider_path(uuid, text)
  to authenticated, anon, service_role;

do $fixtures$
declare
  provider_a uuid := pg_catalog.gen_random_uuid();
  provider_b uuid := pg_catalog.gen_random_uuid();
  unsaved_provider uuid := pg_catalog.gen_random_uuid();
  customer uuid := pg_catalog.gen_random_uuid();
  category_id uuid;
  active_ids uuid[] := '{}'::uuid[];
  inactive_id uuid := pg_catalog.gen_random_uuid();
  other_bucket text := 'provider-rls-' || pg_catalog.gen_random_uuid()::text;
  relation_name text;
  routine_name text;
  api_role text;
  index_number integer;
begin
  perform pg_temp.provider_assert(current_user = 'postgres', 'whole test runs initially as postgres');
  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    foreach api_role in array array['authenticated', 'service_role'] loop
      perform pg_temp.provider_assert(
        pg_catalog.has_table_privilege(api_role, relation_name, 'SELECT')
        and not pg_catalog.has_table_privilege(api_role, relation_name, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        and not pg_catalog.has_any_column_privilege(api_role, relation_name, 'INSERT,UPDATE,REFERENCES'),
        api_role || ' has SELECT-only table/column ACLs: ' || relation_name
      );
    end loop;
    perform pg_temp.provider_assert(
      not pg_catalog.has_table_privilege('anon', relation_name, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not pg_catalog.has_any_column_privilege('anon', relation_name, 'SELECT,INSERT,UPDATE,REFERENCES')
      and (select relrowsecurity from pg_catalog.pg_class where oid = relation_name::regclass),
      'anon denied and RLS enabled: ' || relation_name
    );
  end loop;
  foreach routine_name in array array[
    'public.get_provider_onboarding(uuid)',
    'public.save_provider_onboarding(uuid,text,uuid[],text[],jsonb)',
    'public.submit_provider_verification(uuid,text,boolean)'
  ] loop
    perform pg_temp.provider_assert(
      pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE'),
      'client RPC ACL: ' || routine_name
    );
  end loop;
  perform pg_temp.provider_assert(
    pg_catalog.has_function_privilege('service_role', 'public.review_provider_verification(uuid,text,text,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated', 'public.review_provider_verification(uuid,text,text,text)', 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', 'public.review_provider_verification(uuid,text,text,text)', 'EXECUTE'),
    'only service_role can execute review RPC among API roles'
  );
  foreach routine_name in array array[
    'salahly_private.lock_provider(uuid)', 'salahly_private.provider_snapshot(uuid)',
    'salahly_private.guard_provider_document()'
  ] loop
    perform pg_temp.provider_assert(
      not pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE'),
      'internal helper not executable by API roles: ' || routine_name
    );
  end loop;
  perform pg_temp.provider_assert(not exists (
    select 1 from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where (namespace.nspname = 'salahly_private' or (namespace.nspname = 'public' and routine.proname in (
      'get_provider_onboarding', 'save_provider_onboarding', 'submit_provider_verification', 'review_provider_verification'
    ))) and (
      not routine.prosecdef or pg_catalog.pg_get_userbyid(routine.proowner) <> 'postgres'
      or not coalesce(routine.proconfig @> array['search_path=""'], false)
      or pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE')
    )
  ), 'every M5 definer has postgres owner, empty search_path, and no PUBLIC/anon execution');
  perform pg_temp.provider_assert(not pg_catalog.has_schema_privilege('anon', 'salahly_private', 'USAGE'),
    'private helper schema is not available to anon');
  perform pg_temp.provider_assert(not pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE'),
    'foundation provider/customer role remains client immutable');
  perform pg_temp.provider_assert(exists (
    select 1 from storage.buckets where id = 'provider-verification' and name = id and not public
      and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg', 'image/png']
  ), 'private bucket has exact JPEG/PNG and 5 MiB limits');
  perform pg_temp.provider_assert((
    select pg_catalog.count(*) from pg_catalog.pg_policies
    where schemaname = 'storage' and permissive = 'RESTRICTIVE'
      and policyname in (
        'salahly_provider_objects_client_gate', 'salahly_provider_objects_select_guard',
        'salahly_provider_objects_insert_guard', 'salahly_provider_objects_update_guard',
        'salahly_provider_objects_delete_guard', 'salahly_provider_bucket_insert_guard',
        'salahly_provider_bucket_update_guard', 'salahly_provider_bucket_delete_guard'
      )
  ) = 8, 'all eight bucket-scoped restrictive guards exist');
  perform pg_temp.provider_assert(exists (
    select 1 from pg_catalog.pg_constraint where conrelid = 'public.provider_verifications'::regclass
      and confrelid = 'storage.objects'::regclass and contype = 'f' and confdeltype = 'r'
      and convalidated and not condeferrable
  ), 'verification evidence has a validated non-deferrable DELETE RESTRICT FK');

  perform pg_catalog.set_config('provider_test.a', provider_a::text, true);
  perform pg_catalog.set_config('provider_test.b', provider_b::text, true);
  perform pg_catalog.set_config('provider_test.unsaved', unsaved_provider::text, true);
  perform pg_catalog.set_config('provider_test.customer', customer::text, true);
  perform pg_catalog.set_config('provider_test.other_bucket', other_bucket, true);
  perform pg_catalog.set_config('provider_test.a1', pg_temp.provider_path(provider_a), true);
  perform pg_catalog.set_config('provider_test.a2', pg_temp.provider_path(provider_a, '.png'), true);
  perform pg_catalog.set_config('provider_test.a3', pg_temp.provider_path(provider_a), true);
  perform pg_catalog.set_config('provider_test.b1', pg_temp.provider_path(provider_b, '.png'), true);
  perform pg_catalog.set_config('provider_test.other_path', pg_temp.provider_path(provider_a), true);
  insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    select id, 'authenticated', 'authenticated', 'provider-rls-' || id::text || '@example.invalid',
      '{"provider":"email","providers":["email"]}'::jsonb,
      pg_catalog.jsonb_build_object('full_name', 'Provider SQL Fixture', 'role', app_role, 'is_admin', true),
      pg_catalog.now(), pg_catalog.now()
    from (values (provider_a, 'provider'), (provider_b, 'provider'),
      (unsaved_provider, 'provider'), (customer, 'admin')) as fixture(id, app_role);
  -- Later metadata, including forged admin flags, cannot promote this customer.
  update auth.users set raw_user_meta_data = '{"role":"provider","is_admin":true}'::jsonb where id = customer;
  perform pg_temp.provider_assert((select role = 'customer' from public.profiles where id = customer),
    'admin signup flags and later metadata do not grant provider access');

  for index_number in 1..21 loop
    category_id := pg_catalog.gen_random_uuid();
    active_ids := pg_catalog.array_append(active_ids, category_id);
    insert into public.service_categories (id, slug, name_en, name_ar, description_en, description_ar, icon_key)
      values (category_id, 'provider_test_' || category_id::text, 'Fixture', 'Fixture', 'Fixture', 'Fixture', 'plumbing');
  end loop;
  insert into public.service_categories (id, slug, name_en, name_ar, description_en, description_ar, icon_key, is_active)
    values (inactive_id, 'provider_test_' || inactive_id::text, 'Inactive', 'Inactive', 'Fixture', 'Fixture', 'plumbing', false);
  perform pg_catalog.set_config('provider_test.active_ids', active_ids::text, true);
  perform pg_catalog.set_config('provider_test.inactive', inactive_id::text, true);
  insert into storage.buckets (id, name, public) values (other_bucket, other_bucket, true);
  insert into storage.objects (bucket_id, name, owner_id, metadata) values (
    other_bucket, pg_catalog.current_setting('provider_test.other_path'), provider_a::text,
    '{"mimetype":"image/jpeg","size":1234}'::jsonb
  );
end;
$fixtures$;

-- Intentionally hostile, unrelated existing policies must not override M5.
grant select, insert, update, delete on storage.objects, storage.buckets to authenticated, anon;
create policy salahly_provider_test_allow_all_objects on storage.objects
  for all to public using (true) with check (true);
create policy salahly_provider_test_allow_all_buckets on storage.buckets
  for all to public using (true) with check (true);

select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.b'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.b'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $other_provider$
declare
  own_id uuid := auth.uid();
  skills uuid[] := pg_catalog.current_setting('provider_test.active_ids')::uuid[];
  result jsonb;
begin
  result := public.save_provider_onboarding(own_id, 'Experienced provider with local service coverage.',
    skills[1:1], array['Alexandria'], '[{"weekday":1,"start_minute":480,"end_minute":1020}]'::jsonb);
  insert into storage.objects (bucket_id, name, owner_id, metadata) values (
    'provider-verification', pg_catalog.current_setting('provider_test.b1'), own_id::text,
    '{"mimetype":"image/png","size":2048}'::jsonb
  );
  result := public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.b1'), true);
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'pending', 'other provider can save/upload/submit own draft');
  perform pg_catalog.set_config('provider_test.b_verification', result #>> '{verification,id}', true);
end;
$other_provider$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.unsaved'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.unsaved'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $unsaved$
declare
  own_id uuid := auth.uid();
  result jsonb;
  path text := pg_temp.provider_path(own_id);
begin
  result := public.get_provider_onboarding(own_id);
  perform pg_temp.provider_assert(result = pg_catalog.jsonb_build_object('user_id', own_id,
    'bio', '', 'skill_ids', '[]'::jsonb, 'service_areas', '[]'::jsonb,
    'availability', '[]'::jsonb, 'verification', null)
    and not exists (select 1 from public.provider_profiles where user_id = own_id),
    'empty read returns exact empty snapshot without creating a profile');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (%L,%L,%L)',
    'provider-verification', path, own_id), 'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.submit_provider_verification(%L,%L,true)', own_id, path), 'P0001', 'provider.errors.incomplete');
end;
$unsaved$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.a'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.a'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $draft_validation$
declare
  own_id uuid := auth.uid();
  other_id uuid := pg_catalog.current_setting('provider_test.b')::uuid;
  skills uuid[] := pg_catalog.current_setting('provider_test.active_ids')::uuid[];
  inactive uuid := pg_catalog.current_setting('provider_test.inactive')::uuid;
  good_bio text := 'Experienced local plumbing and electrical provider.';
  good_areas text[] := array['Cairo', 'Giza'];
  good_hours jsonb := '[{"weekday":7,"start_minute":1439,"end_minute":1440},{"weekday":1,"start_minute":0,"end_minute":1440}]'::jsonb;
  before_snapshot jsonb;
  result jsonb;
  invalid record;
  relation_name text;
  max_hours jsonb;
  max_areas text[];
  affected integer;
begin
  perform pg_temp.provider_assert(current_user = 'authenticated' and own_id = pg_catalog.current_setting('provider_test.a')::uuid,
    'provider test actually uses authenticated DB role and matching subject');
  result := public.save_provider_onboarding(own_id, E' \t\r\n ', '{}'::uuid[], '{}'::text[], '[]'::jsonb);
  perform pg_temp.provider_assert(result ->> 'bio' = '' and result -> 'skill_ids' = '[]'::jsonb
    and result -> 'service_areas' = '[]'::jsonb and result -> 'availability' = '[]'::jsonb
    and result -> 'verification' = 'null'::jsonb,
    'empty drafts, including whitespace-trimmed bio, can be saved');

  -- An INSERT preflight with no final metadata works only after saving a row.
  insert into storage.objects (bucket_id, name, owner_id) values ('provider-verification',
    pg_catalog.current_setting('provider_test.a3'), own_id::text);
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.submit_provider_verification(%L,%L,true)', own_id,
    pg_catalog.current_setting('provider_test.a3')), 'P0001', 'provider.errors.incomplete');
  delete from storage.objects where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a3');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 1, 'own unreferenced preflight object can be cleaned up');

  before_snapshot := public.save_provider_onboarding(own_id, E' \n' || good_bio || E'\t ', skills[1:2],
    array[E' \tCairo\n ', ' Giza '], good_hours);
  perform pg_temp.provider_assert(before_snapshot ->> 'bio' = good_bio
    and before_snapshot -> 'service_areas' = '["Cairo","Giza"]'::jsonb
    and before_snapshot -> 'skill_ids' = pg_catalog.to_jsonb(skills[1:2])
    and before_snapshot #>> '{availability,0,weekday}' = '1'
    and before_snapshot #>> '{availability,1,weekday}' = '7',
    'save trims fields, preserves skill/area order, and sorts ISO weekdays');

  for invalid in select * from (values
    (null::text, skills[1:1], good_areas, good_hours, 'invalid_profile'),
    (good_bio, null::uuid[], good_areas, good_hours, 'invalid_profile'),
    (good_bio, skills[1:1], null::text[], good_hours, 'invalid_profile'),
    (good_bio, skills[1:1], good_areas, null::jsonb, 'invalid_profile'),
    (pg_catalog.repeat('x', 1001), skills[1:1], good_areas, good_hours, 'bio'),
    (good_bio, skills, good_areas, good_hours, 'skills'),
    (good_bio, array[skills[1], skills[1]], good_areas, good_hours, 'skills'),
    (good_bio, array[null::uuid], good_areas, good_hours, 'skills'),
    (good_bio, array[inactive], good_areas, good_hours, 'skills'),
    (good_bio, array[pg_catalog.gen_random_uuid()], good_areas, good_hours, 'skills'),
    (good_bio, array[[skills[1], skills[2]]], good_areas, good_hours, 'skills'),
    (good_bio, skills[1:1], array['x'], good_hours, 'areas'),
    (good_bio, skills[1:1], array[''], good_hours, 'areas'),
    (good_bio, skills[1:1], array[E' \n\t '], good_hours, 'areas'),
    (good_bio, skills[1:1], array[pg_catalog.repeat('x', 101)], good_hours, 'areas'),
    (good_bio, skills[1:1], array['Cairo', ' cairo '], good_hours, 'areas'),
    (good_bio, skills[1:1], array[null::text], good_hours, 'areas'),
    (good_bio, skills[1:1], array['AA','BB','CC','DD','EE','FF','GG','HH','II','JJ','KK'], good_hours, 'areas'),
    (good_bio, skills[1:1], array[['AA','BB']], good_hours, 'areas')
  ) as payload(bio, skill_ids, areas, hours, error_key) loop
    perform pg_temp.provider_expect_error(pg_catalog.format(
      'select public.save_provider_onboarding(%L::uuid,%L::text,%L::uuid[],%L::text[],%L::jsonb)',
      own_id, invalid.bio, invalid.skill_ids, invalid.areas, invalid.hours), 'P0001', 'provider.errors.' || invalid.error_key);
    perform pg_temp.provider_assert(public.get_provider_onboarding(own_id) = before_snapshot,
      'invalid bio/arrays leave the entire saved profile unchanged');
  end loop;

  for invalid in select value as hours from pg_catalog.jsonb_array_elements($json$[
    {}, null, true, 0, "[]", [null], [1], [[]], [{}],
    [{"weekday":1,"start_minute":0}],
    [{"weekday":1,"start_minute":0,"end_minute":60,"status":"verified"}],
    [{"weekday":1,"start_minute":0,"end_minute":60,"timezone":"UTC"}],
    [{"weekday":"1","start_minute":0,"end_minute":60}],
    [{"weekday":1,"start_minute":"0","end_minute":60}],
    [{"weekday":1,"start_minute":0,"end_minute":"60"}],
    [{"weekday":1.5,"start_minute":0,"end_minute":60}],
    [{"weekday":1,"start_minute":0.5,"end_minute":60}],
    [{"weekday":1,"start_minute":0,"end_minute":60.5}],
    [{"weekday":1e100,"start_minute":0,"end_minute":60}],
    [{"weekday":0,"start_minute":0,"end_minute":60}],
    [{"weekday":8,"start_minute":0,"end_minute":60}],
    [{"weekday":-1,"start_minute":0,"end_minute":60}],
    [{"weekday":1,"start_minute":-1,"end_minute":60}],
    [{"weekday":1,"start_minute":1440,"end_minute":1440}],
    [{"weekday":1,"start_minute":0,"end_minute":0}],
    [{"weekday":1,"start_minute":0,"end_minute":1441}],
    [{"weekday":1,"start_minute":60,"end_minute":60}],
    [{"weekday":1,"start_minute":61,"end_minute":60}],
    [{"weekday":1,"start_minute":0,"end_minute":60},{"weekday":1,"start_minute":60,"end_minute":120}],
    [{"weekday":1,"start_minute":0,"end_minute":60},{"weekday":2,"start_minute":0,"end_minute":60},
     {"weekday":3,"start_minute":0,"end_minute":60},{"weekday":4,"start_minute":0,"end_minute":60},
     {"weekday":5,"start_minute":0,"end_minute":60},{"weekday":6,"start_minute":0,"end_minute":60},
     {"weekday":7,"start_minute":0,"end_minute":60},{"weekday":1,"start_minute":60,"end_minute":120}]
  ]$json$::jsonb) loop
    perform pg_temp.provider_expect_error(pg_catalog.format(
      'select public.save_provider_onboarding(%L,%L,%L::uuid[],%L::text[],%L::jsonb)',
      own_id, good_bio, skills[1:1], good_areas, invalid.hours), 'P0001', 'provider.errors.availability');
    perform pg_temp.provider_assert(public.get_provider_onboarding(own_id) = before_snapshot,
      'invalid availability leaves all normalized tables unchanged');
  end loop;

  select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('weekday', day, 'start_minute', 0, 'end_minute', 1440))
    into max_hours from pg_catalog.generate_series(1, 7) as series(day);
  select pg_catalog.array_agg(pg_catalog.repeat('a', 98) || pg_catalog.lpad(number::text, 2, '0'))
    into max_areas from pg_catalog.generate_series(1, 10) as series(number);
  result := public.save_provider_onboarding(own_id, pg_catalog.repeat('x', 1000), skills[1:20], max_areas, max_hours);
  perform pg_temp.provider_assert(pg_catalog.char_length(result ->> 'bio') = 1000
    and pg_catalog.jsonb_array_length(result -> 'skill_ids') = 20
    and pg_catalog.jsonb_array_length(result -> 'service_areas') = 10
    and pg_catalog.jsonb_array_length(result -> 'availability') = 7,
    'all documented save upper bounds are accepted');
  result := public.save_provider_onboarding(own_id, good_bio, skills[1:2], good_areas, good_hours);
  perform pg_temp.provider_assert(result = before_snapshot, 'atomic replacement removes old skills/areas/days without duplicates');
  perform pg_catalog.set_config('provider_test.original_snapshot', result::text, true);

  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    execute pg_catalog.format('select pg_catalog.count(*) from %s where user_id <> auth.uid()', relation_name) into affected;
    perform pg_temp.provider_assert(affected = 0, 'foreign rows hidden: ' || relation_name);
    perform pg_temp.provider_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.provider_expect_error('update ' || relation_name || ' set user_id = user_id where user_id = auth.uid()', '42501');
    perform pg_temp.provider_expect_error('delete from ' || relation_name || ' where user_id = auth.uid()', '42501');
  end loop;
  perform pg_temp.provider_assert((select pg_catalog.count(*) from public.provider_profiles) = 1
    and (select pg_catalog.count(*) from public.provider_skills) = 2
    and (select pg_catalog.count(*) from public.provider_service_areas) = 2
    and (select pg_catalog.count(*) from public.provider_availability) = 2
    and not exists (select 1 from public.provider_verifications), 'own normalized rows readable, other provider verification hidden');
  perform pg_temp.provider_expect_error('update public.profiles set role = ''customer'' where id = auth.uid()', '42501');
  perform pg_temp.provider_expect_error('update public.profiles set role = ''admin'' where id = auth.uid()', '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.get_provider_onboarding(%L)', other_id), '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error('select public.get_provider_onboarding(null)', '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.save_provider_onboarding(%L,'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)', other_id), '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error('select public.save_provider_onboarding(null,'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)',
    '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.submit_provider_verification(%L,%L,true)', other_id, pg_catalog.current_setting('provider_test.b1')),
    '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error('select public.submit_provider_verification(null,null,true)', '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.review_provider_verification(%L,''verified'',null,''forged reviewer'')',
    pg_catalog.current_setting('provider_test.b_verification')), '42501');
  perform pg_temp.provider_expect_error('select salahly_private.provider_snapshot(auth.uid())', '42501');
  perform pg_temp.provider_expect_error('select salahly_private.lock_provider(auth.uid())', '42501');
end;
$draft_validation$;

do $storage_validation$
declare
  own_id uuid := auth.uid();
  other_id uuid := pg_catalog.current_setting('provider_test.b')::uuid;
  path text;
  invalid record;
  affected integer;
begin
  perform pg_temp.provider_assert(not exists (select 1 from storage.objects
    where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.b1')),
    'broad permissive policy cannot reveal another provider document');
  delete from storage.objects where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.b1');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'foreign document DELETE is filtered despite broad policy');

  for path in select value from pg_catalog.unnest(array[
    own_id::text || '/../' || pg_catalog.repeat('a', 32) || '.jpg',
    own_id::text || '//' || pg_catalog.repeat('a', 32) || '.jpg',
    own_id::text || '/' || pg_catalog.repeat('a', 31) || '.jpg',
    own_id::text || '/' || pg_catalog.repeat('a', 33) || '.jpg',
    own_id::text || '/' || pg_catalog.repeat('A', 32) || '.jpg',
    own_id::text || '/' || pg_catalog.repeat('a', 32) || '.jpeg',
    own_id::text || '/' || pg_catalog.repeat('a', 32) || '.PNG',
    own_id::text || '/' || pg_catalog.repeat('a', 32) || '.pdf',
    own_id::text || '/' || pg_catalog.repeat('a', 32) || '.jpg/extra',
    own_id::text || '/%2e%2e%2f' || pg_catalog.repeat('a', 32) || '.jpg',
    own_id::text || '/' || pg_catalog.repeat('a', 32) || E'.jpg\n',
    'https://example.invalid/' || pg_temp.provider_path(own_id),
    '../' || pg_temp.provider_path(own_id), ''
  ]) as invalid_path(value) loop
    perform pg_temp.provider_expect_error(pg_catalog.format(
      'insert into storage.objects(bucket_id,name,owner_id) values (''provider-verification'',%L,%L)', path, own_id),
      'P0001', 'provider.errors.document_unavailable');
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)', own_id, path),
      'P0001', 'provider.errors.document_unavailable');
  end loop;
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''provider-verification'',%L,%L)',
    pg_temp.provider_path(other_id), other_id), '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id,metadata) values (''provider-verification'',%L,%L,%L::jsonb)',
    pg_temp.provider_path(own_id), other_id, pg_catalog.jsonb_build_object('owner', own_id, 'mimetype', 'image/jpeg', 'size', 1)),
    'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id,owner) values (''provider-verification'',%L,%L,%L)',
    pg_temp.provider_path(own_id), own_id, other_id), 'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner) values (''provider-verification'',%L,%L)',
    pg_temp.provider_path(own_id), own_id), 'P0001', 'provider.errors.document_unavailable');

  for invalid in select * from (values
    (null::jsonb, 'document_type'),
    ('42'::jsonb, 'document_type'),
    ('{}'::jsonb, 'document_type'),
    ('{"mimetype":null,"size":1}'::jsonb, 'document_type'),
    ('{"mimetype":"image/png","size":1}'::jsonb, 'document_type'),
    ('{"mimetype":"application/pdf","size":1}'::jsonb, 'document_type'),
    ('{"mimetype":"image/jpeg; charset=utf-8","size":1}'::jsonb, 'document_type'),
    ('{"mimetype":"IMAGE/JPEG","size":1}'::jsonb, 'document_type'),
    ('{"mimetype":"image/jpeg"}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":null}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":"1"}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":0}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":-1}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":5242881}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":1.5}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":1e100}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":true}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":[]}'::jsonb, 'document_size'),
    ('{"mimetype":"image/jpeg","size":{}}'::jsonb, 'document_size')
  ) as fixture(metadata, error_key) loop
    path := pg_temp.provider_path(own_id);
    insert into storage.objects (bucket_id, name, owner_id, metadata, user_metadata) values (
      'provider-verification', path, own_id::text, invalid.metadata,
      '{"mimetype":"image/jpeg","size":100,"owner_id":"forged"}'::jsonb
    );
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)', own_id, path),
      'P0001', 'provider.errors.' || invalid.error_key);
    delete from storage.objects where bucket_id = 'provider-verification' and name = path;
    get diagnostics affected = row_count;
    perform pg_temp.provider_assert(affected = 1 and not exists (select 1 from public.provider_verifications),
      'invalid finalized metadata cannot submit; caller user_metadata is ignored; unreferenced cleanup works');
  end loop;

  insert into storage.objects (bucket_id, name, owner_id, owner, metadata) values
    ('provider-verification', pg_catalog.current_setting('provider_test.a1'), own_id::text, own_id, '{"mimetype":"image/jpeg","size":1}'),
    ('provider-verification', pg_catalog.current_setting('provider_test.a2'), own_id::text, null, '{"mimetype":"image/png","size":5242880}'),
    ('provider-verification', pg_catalog.current_setting('provider_test.a3'), own_id::text, null, '{"mimetype":"image/jpeg","size":4096}');
  perform pg_temp.provider_assert((select pg_catalog.count(*) from storage.objects
    where bucket_id = 'provider-verification') = 3, 'own provider can SELECT/download only own three valid objects');
  update storage.objects set metadata = '{"mimetype":"image/jpeg","size":99}' where bucket_id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'no UPDATE policy, even with broad permissive ALL policy');
  update storage.objects set name = pg_temp.provider_path(own_id), owner_id = other_id::text,
    bucket_id = pg_catalog.current_setting('provider_test.other_bucket') where bucket_id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'objects cannot be renamed, transferred, or moved out of the bucket');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'update storage.objects set bucket_id = ''provider-verification'' where bucket_id = %L and name = %L',
    pg_catalog.current_setting('provider_test.other_bucket'), pg_catalog.current_setting('provider_test.other_path')),
    'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(id,bucket_id,name,owner_id) select id,bucket_id,name,owner_id from storage.objects where bucket_id = ''provider-verification'' and name = %L on conflict (id) do update set metadata = ''{}''::jsonb',
    pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.document_unavailable');

  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,false)',
    own_id, pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.consent');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,null)',
    own_id, pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.consent');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,null,true)', own_id),
    'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    own_id, pg_temp.provider_path(own_id)), 'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    own_id, pg_catalog.current_setting('provider_test.other_path')), 'P0001', 'provider.errors.document_unavailable');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    own_id, pg_catalog.current_setting('provider_test.b1')), 'P0001', 'provider.errors.document_unavailable');

  update storage.buckets set public = true, file_size_limit = 99999999, allowed_mime_types = null where id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'client cannot make verification bucket public or relax limits');
  delete from storage.buckets where id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'client cannot delete verification bucket');
  perform pg_temp.provider_expect_error(
    'insert into storage.buckets(id,name,public) values (''provider-verification'',''forged'',true)', '42501');
end;
$storage_validation$;

-- Submission rechecks current category activity, not just the previous save.
set local role postgres;
update public.service_categories set is_active = false
  where id = (pg_catalog.current_setting('provider_test.active_ids')::uuid[])[1];
set local role authenticated;
select pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
  auth.uid(), pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.skills');
set local role postgres;
update public.service_categories set is_active = true
  where id = (pg_catalog.current_setting('provider_test.active_ids')::uuid[])[1];
set local role authenticated;

do $submission$
declare
  own_id uuid := auth.uid();
  skills uuid[] := pg_catalog.current_setting('provider_test.active_ids')::uuid[];
  result jsonb;
  retry jsonb;
  affected integer;
  invalid record;
begin
  for invalid in select * from (values
    (pg_catalog.repeat('x', 19), skills[1:1], array['Cairo'], '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb),
    (pg_catalog.repeat('x', 20), '{}'::uuid[], array['Cairo'], '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb),
    (pg_catalog.repeat('x', 20), skills[1:1], '{}'::text[], '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb),
    (pg_catalog.repeat('x', 20), skills[1:1], array['Cairo'], '[]'::jsonb)
  ) as fixture(bio, skill_ids, areas, hours) loop
    perform public.save_provider_onboarding(own_id, invalid.bio, invalid.skill_ids, invalid.areas, invalid.hours);
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
      own_id, pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.incomplete');
  end loop;
  perform public.save_provider_onboarding(own_id, pg_catalog.repeat('x', 20), skills[1:1], array['Cairo'],
    '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb);
  result := public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.a1'), true);
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'pending'
    and result #>> '{verification,mime_type}' = 'image/jpeg'
    and result #>> '{verification,size_bytes}' = '1'
    and result #> '{verification,reviewed_at}' = 'null'::jsonb
    and result #> '{verification,review_note}' = 'null'::jsonb,
    'minimum complete profile, explicit consent, and one-byte JPEG metadata create pending only');
  perform pg_catalog.set_config('provider_test.a_verification1', result #>> '{verification,id}', true);
  perform pg_temp.provider_assert(exists (select 1 from public.provider_verifications
    where id = (result #>> '{verification,id}')::uuid and submitted_profile = result - 'verification'
      and consented_at = submitted_at and consented_at is not null and reviewer is null),
    'submitted profile snapshot and explicit consent timestamp are retained for audit');
  perform pg_catalog.set_config('provider_test.audit1', (result - 'verification')::text, true);
  retry := public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.a1'), true);
  perform pg_temp.provider_assert(retry = result and (select pg_catalog.count(*) from public.provider_verifications) = 1,
    'same-path response-loss retry is idempotent with identical timestamps');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,false)',
    own_id, pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.consent');
  perform pg_temp.provider_expect_error('select public.save_provider_onboarding(auth.uid(),'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)',
    'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    own_id, pg_catalog.current_setting('provider_test.a2')), 'P0001', 'provider.errors.locked');
  delete from storage.objects where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a1');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'pending evidence cannot be deleted by its owner');
  perform pg_temp.provider_expect_error('update public.provider_verifications set status = ''verified'', reviewer = ''self'', reviewed_at = pg_catalog.now()', '42501');
  perform pg_temp.provider_expect_error('update public.provider_verifications set submitted_profile = ''{}''::jsonb, consented_at = pg_catalog.now()', '42501');

  -- Forged JWT application/admin flags cannot grant the service_role SQL ACL.
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', own_id, 'role', 'service_role', 'is_admin', true, 'app_metadata', '{"is_admin":true}'::jsonb)::text, true);
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''verified'',null,''self'')',
    result #>> '{verification,id}'), '42501');
  perform pg_temp.provider_assert(public.get_provider_onboarding(own_id) #>> '{verification,status}' = 'pending',
    'self-review and admin/status escalation did not change pending state');
end;
$submission$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $review_rejection$
declare
  verification_id uuid := pg_catalog.current_setting('provider_test.a_verification1')::uuid;
  result jsonb;
  invalid record;
begin
  perform pg_temp.provider_assert((select pg_catalog.count(*) from public.provider_verifications
    where user_id in (pg_catalog.current_setting('provider_test.a')::uuid, pg_catalog.current_setting('provider_test.b')::uuid)) = 2,
    'trusted service_role can read audit rows across providers');
  perform pg_temp.provider_expect_error('update public.provider_verifications set status = ''verified''', '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.get_provider_onboarding(%L)',
    pg_catalog.current_setting('provider_test.a')), '42501');
  for invalid in select * from (values
    (null::text, null::text, 'reviewer'), ('pending', null, 'reviewer'), ('draft', null, 'reviewer'),
    ('admin', null, 'reviewer'), ('rejected', null, 'reviewer'), ('rejected', E' \t\n ', 'reviewer'),
    ('rejected', pg_catalog.repeat('x', 501), 'reviewer'), ('verified', pg_catalog.repeat('x', 501), 'reviewer'),
    ('verified', null, null), ('verified', null, E' \r\n ')
  ) as fixture(decision, note, reviewer) loop
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,%L,%L,%L)',
      verification_id, invalid.decision, invalid.note, invalid.reviewer), 'P0001', 'provider.errors.invalid_profile');
  end loop;
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''verified'',null,''reviewer'')',
    pg_catalog.gen_random_uuid()), 'P0001', 'provider.errors.document_unavailable');
  result := public.review_provider_verification(verification_id, 'rejected', ' ' || pg_catalog.repeat('r', 500) || ' ', '  reviewer@example.invalid  ');
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'rejected'
    and pg_catalog.char_length(result #>> '{verification,review_note}') = 500
    and result #> '{verification,reviewed_at}' <> 'null'::jsonb
    and (select reviewer = 'reviewer@example.invalid' from public.provider_verifications where id = verification_id),
    'trusted rejection records trimmed 500-character note and reviewer audit identity');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''verified'',null,''reviewer'')',
    verification_id), 'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'delete from storage.objects where bucket_id = ''provider-verification'' and name = %L',
    pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'update storage.objects set metadata = ''{"mimetype":"image/jpeg","size":2}''::jsonb where bucket_id = ''provider-verification'' and name = %L',
    pg_catalog.current_setting('provider_test.a1')), 'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'update storage.objects set version = ''replaced'' where bucket_id = ''provider-verification'' and name = %L',
    pg_catalog.current_setting('provider_test.a3')), 'P0001', 'provider.errors.locked');
  -- Hosted Storage has a generated path_tokens column that is not computed
  -- yet in a BEFORE UPDATE trigger. Access-only timestamp writes must work.
  update storage.objects set last_accessed_at = '2026-10-18T00:00:00Z'::timestamptz
    where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a1');
  perform pg_temp.provider_assert(exists (select 1 from storage.objects
    where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a1')
      and last_accessed_at = '2026-10-18T00:00:00Z'::timestamptz),
    'trusted access timestamp updates preserve immutable evidence, including generated Storage columns');
end;
$review_rejection$;

set local role postgres;
-- PostgreSQL 18 distinguishes RESTRICT (23001); older hosted versions report
-- the same FK protection as foreign_key_violation (23503).
select pg_temp.provider_expect_error(pg_catalog.format('delete from public.profiles where id = %L',
  pg_catalog.current_setting('provider_test.a')), '23001,23503');
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.a'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.a'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $resubmission$
declare
  own_id uuid := auth.uid();
  skills uuid[] := pg_catalog.current_setting('provider_test.active_ids')::uuid[];
  result jsonb;
  affected integer;
begin
  result := public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.a1'), true);
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'rejected'
    and (select pg_catalog.count(*) from public.provider_verifications) = 1,
    'retrying a rejected path returns existing rejection, not a new submission');
  delete from storage.objects where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a1');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'rejected evidence is retained even for its owner');
  result := public.save_provider_onboarding(own_id, 'Updated local service profile for a new credential.', skills[2:2], array['Giza'],
    '[{"weekday":7,"start_minute":1439,"end_minute":1440}]'::jsonb);
  result := public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.a2'), true);
  perform pg_catalog.set_config('provider_test.a_verification2', result #>> '{verification,id}', true);
  perform pg_catalog.set_config('provider_test.audit2', (result - 'verification')::text, true);
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'pending'
    and result #>> '{verification,mime_type}' = 'image/png'
    and result #>> '{verification,size_bytes}' = '5242880'
    and (select pg_catalog.count(*) from public.provider_verifications) = 2
    and exists (select 1 from public.provider_verifications
      where id = pg_catalog.current_setting('provider_test.a_verification1')::uuid and status = 'rejected'
        and submitted_profile = pg_catalog.current_setting('provider_test.audit1')::jsonb),
    'new PNG at 5 MiB resubmits after rejection while old audit/evidence remain unchanged');
  perform pg_temp.provider_assert(public.submit_provider_verification(own_id, pg_catalog.current_setting('provider_test.a1'), true) = result,
    'late retry of an older rejected path returns the latest snapshot without duplicating it');
  perform pg_temp.provider_expect_error('select public.save_provider_onboarding(auth.uid(),'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)',
    'P0001', 'provider.errors.locked');
end;
$resubmission$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $review_approval$
declare
  verification_id uuid := pg_catalog.current_setting('provider_test.a_verification2')::uuid;
  result jsonb;
begin
  result := public.review_provider_verification(verification_id, 'verified', null, 'trusted-reviewer-2');
  perform pg_temp.provider_assert(result #>> '{verification,status}' = 'verified'
    and result #> '{verification,review_note}' = 'null'::jsonb, 'trusted approval may omit review note');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''rejected'',''changed mind'',''reviewer'')',
    verification_id), 'P0001', 'provider.errors.locked');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''verified'',null,''reviewer'')',
    verification_id), 'P0001', 'provider.errors.locked');
end;
$review_approval$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.a'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.a'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $verified_edits$
declare
  result jsonb;
  affected integer;
begin
  result := public.save_provider_onboarding(auth.uid(), '', '{}'::uuid[], '{}'::text[], '[]'::jsonb);
  perform pg_temp.provider_assert(result ->> 'bio' = '' and result #>> '{verification,status}' = 'verified',
    'verified provider may edit even an empty self-listed draft without changing credential status');
  perform pg_temp.provider_assert(public.submit_provider_verification(auth.uid(), pg_catalog.current_setting('provider_test.a2'), true) = result,
    'same verified file retry remains idempotent after live profile changes');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(auth.uid(),%L,true)',
    pg_catalog.current_setting('provider_test.a3')), 'P0001', 'provider.errors.locked');
  perform pg_temp.provider_assert(exists (select 1 from public.provider_verifications
    where id = pg_catalog.current_setting('provider_test.a_verification2')::uuid
      and submitted_profile = pg_catalog.current_setting('provider_test.audit2')::jsonb),
    'verified live edits never rewrite submitted profile/consent audit');
  delete from storage.objects where bucket_id = 'provider-verification' and name in (
    pg_catalog.current_setting('provider_test.a1'), pg_catalog.current_setting('provider_test.a2'));
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'neither verified nor prior rejected evidence can be deleted');
  delete from storage.objects where bucket_id = 'provider-verification' and name = pg_catalog.current_setting('provider_test.a3');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 1, 'unused upload cleanup remains allowed after verification');
  perform pg_temp.provider_assert((select pg_catalog.count(*) from public.provider_verifications) = 2,
    'provider can read own full review history, not foreign verification rows');
end;
$verified_edits$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.b'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.b'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $symmetric_isolation$
declare
  relation_name text;
  foreign_count integer;
begin
  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    execute 'select pg_catalog.count(*) from ' || relation_name || ' where user_id <> auth.uid()' into foreign_count;
    perform pg_temp.provider_assert(foreign_count = 0, 'symmetric foreign-row isolation: ' || relation_name);
  end loop;
  perform pg_temp.provider_assert((select pg_catalog.count(*) from public.provider_verifications) = 1
    and (select pg_catalog.count(*) from storage.objects where bucket_id = 'provider-verification') = 1,
    'second provider still sees only their pending verification and own document');
end;
$symmetric_isolation$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('provider_test.customer'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('provider_test.customer'), 'role', 'authenticated',
    'is_admin', true, 'user_metadata', '{"role":"provider"}'::jsonb)::text, true);
set local role authenticated;
do $customer$
declare
  relation_name text;
  visible_count integer;
  target uuid;
begin
  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    execute 'select pg_catalog.count(*) from ' || relation_name into visible_count;
    perform pg_temp.provider_assert(visible_count = 0, 'customer sees no provider rows: ' || relation_name);
    perform pg_temp.provider_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.provider_expect_error('update ' || relation_name || ' set user_id = auth.uid()', '42501');
    perform pg_temp.provider_expect_error('delete from ' || relation_name, '42501');
  end loop;
  foreach target in array array[auth.uid(), pg_catalog.current_setting('provider_test.a')::uuid] loop
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.get_provider_onboarding(%L)', target), '42501', 'provider.errors.access');
    perform pg_temp.provider_expect_error(pg_catalog.format(
      'select public.save_provider_onboarding(%L,'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)', target), '42501', 'provider.errors.access');
    perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
      target, pg_catalog.current_setting('provider_test.a1')), '42501', 'provider.errors.access');
  end loop;
  perform pg_temp.provider_expect_error('update public.profiles set role = ''provider'' where id = auth.uid()', '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''provider-verification'',%L,%L)',
    pg_temp.provider_path(auth.uid()), auth.uid()), '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''provider-verification'',%L,%L)',
    pg_temp.provider_path(pg_catalog.current_setting('provider_test.a')::uuid), pg_catalog.current_setting('provider_test.a')), '42501');
  perform pg_temp.provider_assert(not exists (select 1 from storage.objects where bucket_id = 'provider-verification'),
    'customer/admin metadata flags cannot download provider documents through broad policies');
end;
$customer$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;
do $missing_identity$
declare
  relation_name text;
  visible_count integer;
begin
  perform pg_temp.provider_assert(auth.uid() is null, 'missing-sub test has no authenticated identity');
  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    execute 'select pg_catalog.count(*) from ' || relation_name into visible_count;
    perform pg_temp.provider_assert(visible_count = 0, 'missing subject exposes no private rows: ' || relation_name);
  end loop;
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.get_provider_onboarding(%L)',
    pg_catalog.current_setting('provider_test.a')), '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.save_provider_onboarding(%L,'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)',
    pg_catalog.current_setting('provider_test.a')), '42501', 'provider.errors.access');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    pg_catalog.current_setting('provider_test.a'), pg_catalog.current_setting('provider_test.a1')), '42501', 'provider.errors.access');
  perform pg_temp.provider_assert(not exists (select 1 from storage.objects where bucket_id = 'provider-verification'),
    'missing subject cannot download documents despite authenticated DB role');
end;
$missing_identity$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
do $anonymous$
declare
  relation_name text;
  affected integer;
  unrelated_name text := 'unrelated-' || pg_catalog.gen_random_uuid()::text;
begin
  foreach relation_name in array array[
    'public.provider_profiles', 'public.provider_skills', 'public.provider_service_areas',
    'public.provider_availability', 'public.provider_verifications'
  ] loop
    perform pg_temp.provider_expect_error('select * from ' || relation_name, '42501');
    perform pg_temp.provider_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.provider_expect_error('update ' || relation_name || ' set user_id = user_id', '42501');
    perform pg_temp.provider_expect_error('delete from ' || relation_name, '42501');
  end loop;
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.get_provider_onboarding(%L)', pg_catalog.current_setting('provider_test.a')), '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'select public.save_provider_onboarding(%L,'''',''{}''::uuid[],''{}''::text[],''[]''::jsonb)', pg_catalog.current_setting('provider_test.a')), '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.submit_provider_verification(%L,%L,true)',
    pg_catalog.current_setting('provider_test.a'), pg_catalog.current_setting('provider_test.a1')), '42501');
  perform pg_temp.provider_expect_error(pg_catalog.format('select public.review_provider_verification(%L,''verified'',null,''anonymous'')',
    pg_catalog.current_setting('provider_test.b_verification')), '42501');
  perform pg_temp.provider_expect_error('select salahly_private.provider_is_self(null)', '42501');
  perform pg_temp.provider_assert(not exists (select 1 from storage.objects where bucket_id = 'provider-verification'),
    'anonymous SELECT cannot override restrictive bucket guard with broad permissive policy');
  perform pg_temp.provider_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''provider-verification'',%L,%L)',
    pg_temp.provider_path(pg_catalog.current_setting('provider_test.a')::uuid), pg_catalog.current_setting('provider_test.a')), '42501');
  update storage.objects set metadata = '{}'::jsonb where bucket_id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'anonymous object UPDATE remains denied');
  delete from storage.objects where bucket_id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'anonymous object DELETE remains denied');
  update storage.buckets set public = true where id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'anonymous cannot expose private bucket');
  delete from storage.buckets where id = 'provider-verification';
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 0, 'anonymous cannot remove private bucket');
  perform pg_temp.provider_expect_error('insert into storage.buckets(id,name) values (''provider-verification'',''anonymous'')', '42501');

  -- This bucket's broad existing access must survive ALL M5 guards/triggers.
  perform pg_temp.provider_assert(exists (select 1 from storage.objects
    where bucket_id = pg_catalog.current_setting('provider_test.other_bucket')), 'unrelated anonymous bucket SELECT remains allowed');
  insert into storage.objects (bucket_id, name, metadata) values (
    pg_catalog.current_setting('provider_test.other_bucket'), unrelated_name, '{"arbitrary":true}'::jsonb);
  update storage.objects set metadata = '{"changed":true}'::jsonb
    where bucket_id = pg_catalog.current_setting('provider_test.other_bucket') and name = unrelated_name;
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 1, 'unrelated anonymous bucket INSERT/UPDATE remain allowed');
  delete from storage.objects where bucket_id = pg_catalog.current_setting('provider_test.other_bucket') and name = unrelated_name;
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 1, 'unrelated anonymous bucket DELETE remains allowed');
  update storage.buckets set public = false where id = pg_catalog.current_setting('provider_test.other_bucket');
  get diagnostics affected = row_count;
  perform pg_temp.provider_assert(affected = 1, 'unrelated bucket settings remain governed by their existing policies');
end;
$anonymous$;

set local role postgres;
do $complete$
begin
  perform pg_temp.provider_assert((select pg_catalog.count(*) from public.provider_verifications
    where user_id = pg_catalog.current_setting('provider_test.a')::uuid) = 2
    and (select pg_catalog.count(*) from storage.objects where bucket_id = 'provider-verification'
      and owner_id in (pg_catalog.current_setting('provider_test.a'), pg_catalog.current_setting('provider_test.b'))) = 3,
    'failed escalation/deletion attempts left both audits and all three referenced objects intact');
  perform pg_temp.provider_assert(exists (select 1 from storage.buckets where id = 'provider-verification'
    and not public and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg', 'image/png']),
    'private bucket configuration survived every client/admin-flag attack');
  perform pg_temp.provider_assert(not exists (select 1 from public.provider_profiles
    where user_id in (pg_catalog.current_setting('provider_test.customer')::uuid, pg_catalog.current_setting('provider_test.unsaved')::uuid)),
    'customer and read-only empty provider never acquired draft rows');
  raise notice 'PASS: all Salahly provider onboarding authorization/Storage SQL checks passed; rolling back every fixture.';
end;
$complete$;

rollback;
