-- Rollback-only M6 request/Storage SQL assertions. Install all three migrations,
-- then run this WHOLE file as postgres in a TEST project. No pgTAP/psql or keys.
-- Never replace ROLLBACK with COMMIT; the final PASS notice is required. On an
-- error, ROLLBACK the aborted transaction before running another test.
--
-- Synthetic users, catalog, metadata, ACLs, and adversarial policies roll back.
-- No existing user/catalog records are edited. Auth hooks may have external
-- effects not covered by rollback, so this is not for a production project.
-- JWT GUCs/SET ROLE test SQL authorization, not JWT validation, Storage HTTP,
-- real JPEG/PNG bytes, signed URLs, PostgREST embedding, or concurrent sessions.

begin;
set local search_path = '';
set local standard_conforming_strings = on;
set local timezone = 'UTC';

create temporary table request_test_scope (unused boolean) on commit drop;
create function pg_temp.request_assert(p_condition boolean, p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  if p_condition is distinct from true then
    raise exception 'FAIL: %', p_label;
  end if;
  raise notice 'PASS: %', p_label;
end;
$function$;

create function pg_temp.request_expect_error(p_sql text, p_state text, p_message text default null)
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

-- Build calls without bypassing the real caller's role or the RPC contract.
create function pg_temp.request_submit_sql(p_id uuid, p_changes jsonb default '{}'::jsonb)
returns text language plpgsql security invoker set search_path = ''
as $function$
declare
  payload jsonb := pg_catalog.jsonb_build_object(
    'category_id', pg_catalog.current_setting('request_test.active'),
    'title', 'Repair kitchen pipe', 'description', 'The kitchen pipe leaks when the tap is running.',
    'city', 'Cairo', 'address', '12 Example Street, apartment 4',
    'preferred_at', null, 'photos', '[]'::jsonb, 'consent', true
  ) || p_changes;
begin
  return pg_catalog.format(
    'select public.submit_service_request(%L::uuid,%L::uuid,%L::text,%L::text,%L::text,%L::text,%L::timestamptz,%L::jsonb,%L::boolean)',
    p_id, payload ->> 'category_id', payload ->> 'title', payload ->> 'description',
    payload ->> 'city', payload ->> 'address', payload ->> 'preferred_at', payload -> 'photos', payload ->> 'consent'
  );
end;
$function$;

create function pg_temp.request_photo(
  p_request uuid, p_id uuid default pg_catalog.gen_random_uuid(), p_type text default 'image/jpeg',
  p_size bigint default 1, p_customer uuid default auth.uid()
)
returns jsonb language sql volatile security invoker set search_path = ''
as $function$
  select pg_catalog.jsonb_build_object(
    'id', p_id, 'storage_path', p_customer::text || '/' || p_request::text || '/' || p_id::text
      || case when p_type = 'image/png' then '.png' else '.jpg' end,
    'mime_type', p_type, 'size_bytes', p_size
  );
$function$;

do $temp_grants$
begin
  execute pg_catalog.format('grant usage on schema %I to authenticated, anon, service_role',
    (select nspname from pg_catalog.pg_namespace where oid = pg_catalog.pg_my_temp_schema()));
end;
$temp_grants$;
grant execute on function pg_temp.request_assert(boolean, text), pg_temp.request_expect_error(text, text, text),
  pg_temp.request_submit_sql(uuid, jsonb), pg_temp.request_photo(uuid, uuid, text, bigint, uuid)
  to authenticated, anon, service_role;

do $fixtures$
declare
  customer_a uuid := pg_catalog.gen_random_uuid();
  customer_b uuid := pg_catalog.gen_random_uuid();
  provider uuid := pg_catalog.gen_random_uuid();
  active_category uuid := pg_catalog.gen_random_uuid();
  inactive_category uuid := pg_catalog.gen_random_uuid();
  other_bucket text := 'requests-rls-' || pg_catalog.gen_random_uuid()::text;
  routine_name text;
  relation_name text;
  api_role text;
  provider_path text;
  verification jsonb;
begin
  perform pg_temp.request_assert(current_user = 'postgres', 'whole request test begins as postgres');
  foreach relation_name in array array['public.service_requests', 'public.service_request_photos'] loop
    foreach api_role in array array['authenticated', 'service_role'] loop
      perform pg_temp.request_assert(pg_catalog.has_table_privilege(api_role, relation_name, 'SELECT')
        and not pg_catalog.has_table_privilege(api_role, relation_name, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        and not pg_catalog.has_any_column_privilege(api_role, relation_name, 'INSERT,UPDATE,REFERENCES'),
        api_role || ' has SELECT-only table/column ACLs: ' || relation_name);
    end loop;
    perform pg_temp.request_assert(not pg_catalog.has_table_privilege('anon', relation_name,
      'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not pg_catalog.has_any_column_privilege('anon', relation_name, 'SELECT,INSERT,UPDATE,REFERENCES')
      and (select relrowsecurity from pg_catalog.pg_class where oid = relation_name::regclass),
      'anon denied and RLS enabled: ' || relation_name);
  end loop;
  foreach routine_name in array array[
    'public.submit_service_request(uuid,uuid,text,text,text,text,timestamptz,jsonb,boolean)',
    'public.get_service_request(uuid)', 'public.cancel_service_request(uuid)'
  ] loop
    perform pg_temp.request_assert(pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE'),
      'only authenticated API role has RPC execution: ' || routine_name);
  end loop;
  foreach routine_name in array array[
    'salahly_private.lock_request_customer(uuid)', 'salahly_private.service_request_snapshot(uuid)',
    'salahly_private.validate_request_photo_metadata(text,jsonb)',
    'salahly_private.guard_service_request_record()', 'salahly_private.guard_request_photo()'
  ] loop
    perform pg_temp.request_assert(not pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE'),
      'internal helper not callable by API roles: ' || routine_name);
  end loop;
  perform pg_temp.request_assert(not exists (
    select 1 from pg_catalog.pg_proc as routine
    join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where (namespace.nspname = 'salahly_private' or (namespace.nspname = 'public' and routine.proname in (
      'submit_service_request', 'get_service_request', 'cancel_service_request'
    ))) and (not routine.prosecdef or pg_catalog.pg_get_userbyid(routine.proowner) <> 'postgres'
      or not coalesce(routine.proconfig @> array['search_path=""'], false)
      or pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE'))
  ), 'M6 and existing private helpers retain postgres/definer/empty-path/no-anon invariants');
  perform pg_temp.request_assert(not pg_catalog.has_schema_privilege('anon', 'salahly_private', 'USAGE')
    and not pg_catalog.has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE'),
    'private schema and authoritative profile roles remain protected');
  perform pg_temp.request_assert(exists (select 1 from storage.buckets where id = 'request-photos'
    and name = id and not public and file_size_limit = 5242880
    and allowed_mime_types = array['image/jpeg', 'image/png']), 'private request bucket has exact type/5 MiB limits');
  perform pg_temp.request_assert((select pg_catalog.count(*) from pg_catalog.pg_policies
    where schemaname = 'storage' and permissive = 'RESTRICTIVE' and policyname in (
      'salahly_request_objects_client_gate', 'salahly_request_objects_select_guard',
      'salahly_request_objects_insert_guard', 'salahly_request_objects_update_guard',
      'salahly_request_objects_delete_guard', 'salahly_request_bucket_insert_guard',
      'salahly_request_bucket_update_guard', 'salahly_request_bucket_delete_guard'
    )) = 8, 'all eight bucket-scoped restrictive guards exist');
  perform pg_temp.request_assert(exists (select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.service_request_photos'::regclass and confrelid = 'storage.objects'::regclass
      and contype = 'f' and confdeltype = 'r' and convalidated and not condeferrable),
    'photo evidence has a validated non-deferrable DELETE RESTRICT object FK');
  perform pg_temp.request_assert(exists (select 1 from pg_catalog.pg_indexes
    where schemaname = 'public' and indexname = 'service_requests_customer_history_idx'
      and indexdef like '%(customer_id, created_at DESC, id DESC)%'),
    'owned history has the contract order index');
  perform pg_temp.request_assert((select pg_catalog.count(*) from pg_catalog.pg_policies
    where schemaname = 'public' and tablename in ('service_requests', 'service_request_photos')) = 2,
    'only the two intended owned SELECT policies exist on request tables');

  perform pg_catalog.set_config('request_test.a', customer_a::text, true);
  perform pg_catalog.set_config('request_test.b', customer_b::text, true);
  perform pg_catalog.set_config('request_test.provider', provider::text, true);
  perform pg_catalog.set_config('request_test.active', active_category::text, true);
  perform pg_catalog.set_config('request_test.inactive', inactive_category::text, true);
  perform pg_catalog.set_config('request_test.other_bucket', other_bucket, true);
  perform pg_catalog.set_config('request_test.zero', pg_catalog.gen_random_uuid()::text, true);
  perform pg_catalog.set_config('request_test.multi', pg_catalog.gen_random_uuid()::text, true);
  perform pg_catalog.set_config('request_test.b_request', pg_catalog.gen_random_uuid()::text, true);
  perform pg_catalog.set_config('request_test.past', pg_catalog.gen_random_uuid()::text, true);
  insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    select id, 'authenticated', 'authenticated', 'requests-rls-' || id::text || '@example.invalid',
      '{"provider":"email","providers":["email"]}'::jsonb,
      pg_catalog.jsonb_build_object('full_name', 'Request SQL Fixture', 'role', app_role),
      pg_catalog.now(), pg_catalog.now()
    from (values (customer_a, 'customer'), (customer_b, 'customer'), (provider, 'provider')) as fixture(id, app_role);
  insert into public.service_categories (id, slug, name_en, name_ar, description_en, description_ar, icon_key, is_active)
    values
      (active_category, 'requests_test_' || active_category::text, 'Original category EN', 'Original category AR',
        'Fixture', 'Fixture', 'plumbing', true),
      (inactive_category, 'requests_test_' || inactive_category::text, 'Inactive EN', 'Inactive AR',
        'Fixture', 'Fixture', 'electrical', false);
  insert into storage.buckets (id, name, public) values (other_bucket, other_bucket, true);
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (other_bucket, 'unrelated-object', customer_a::text, '{"arbitrary":true}'::jsonb);

  -- Give the provider a genuine verified M5 fixture; verification grants no M6 access.
  perform pg_catalog.set_config('request.jwt.claim.sub', provider::text, true);
  perform public.save_provider_onboarding(provider, 'Experienced provider fixture for SQL checks.',
    array[active_category], array['Cairo'], '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb);
  provider_path := provider::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '') || '.jpg';
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('provider-verification', provider_path, provider::text, '{"mimetype":"image/jpeg","size":1}'::jsonb);
  verification := public.submit_provider_verification(provider, provider_path, true);
  perform public.review_provider_verification((verification #>> '{verification,id}')::uuid, 'verified', null, 'rollback-reviewer');
  perform pg_temp.request_assert(exists (select 1 from public.provider_verifications where user_id = provider and status = 'verified'),
    'provider isolation fixture really is verified');
end;
$fixtures$;

-- Hostile permissive policies prove guards, not missing Storage grants, protect M6.
grant select, insert, update, delete on storage.objects, storage.buckets to authenticated, anon;
create policy salahly_request_test_allow_all_objects on storage.objects for all to public using (true) with check (true);
create policy salahly_request_test_allow_all_buckets on storage.buckets for all to public using (true) with check (true);

select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('request_test.b'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('request_test.b'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $customer_b$
declare
  request_id uuid := pg_catalog.current_setting('request_test.b_request')::uuid;
  photo jsonb := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(), 'image/png', 2048);
  result jsonb;
begin
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('request-photos', photo ->> 'storage_path', auth.uid()::text, '{"mimetype":"image/png","size":2048}'::jsonb);
  execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photo))) into result;
  perform pg_temp.request_assert(result ->> 'status' = 'open' and result ->> 'customer_id' = auth.uid()::text
    and result #>> '{photos,0,mime_type}' = 'image/png', 'second customer can upload and submit their own single-photo request');
  perform pg_catalog.set_config('request_test.b_photo', photo::text, true);
  perform pg_catalog.set_config('request_test.b_snapshot', result::text, true);
end;
$customer_b$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('request_test.a'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('request_test.a'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $validation$
declare
  request_id uuid := pg_catalog.gen_random_uuid();
  result jsonb;
  invalid record;
  changes jsonb;
  relation_name text;
begin
  perform pg_temp.request_assert(current_user = 'authenticated' and auth.uid() = pg_catalog.current_setting('request_test.a')::uuid,
    'customer tests run under the expected authenticated role and subject');
  perform pg_temp.request_assert(public.get_service_request(request_id) is null and public.get_service_request(null) is null
    and public.get_service_request(pg_catalog.current_setting('request_test.b_request')::uuid) is null
    and not exists (select 1 from public.service_requests) and not exists (select 1 from public.service_request_photos),
    'absent/non-owned get returns NULL and owned empty history is side-effect free');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.cancel_service_request(%L)', request_id),
    'P0001', 'requests.errors.not_found');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.cancel_service_request(%L)',
    pg_catalog.current_setting('request_test.b_request')), 'P0001', 'requests.errors.not_found');
  perform pg_temp.request_expect_error('select public.cancel_service_request(null)', 'P0001', 'requests.errors.not_found');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.current_setting('request_test.b_request')::uuid),
    'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(null), 'P0001', 'requests.errors.invalid_request');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql('00000000-0000-0000-0000-000000000000'), 'P0001', 'requests.errors.invalid_request');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql('10000000-0000-1000-8000-000000000001'), 'P0001', 'requests.errors.invalid_request');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql('10000000-0000-4000-7000-000000000001'), 'P0001', 'requests.errors.invalid_request');

  for invalid in select * from (values
    ('title', 'null'::jsonb, 'title'), ('title', '""'::jsonb, 'title'), ('title', pg_catalog.to_jsonb(E' \t\n '::text), 'title'),
    ('title', pg_catalog.to_jsonb(pg_catalog.repeat('t', 4)), 'title'), ('title', pg_catalog.to_jsonb(pg_catalog.repeat('t', 121)), 'title'),
    ('description', 'null'::jsonb, 'description'), ('description', pg_catalog.to_jsonb(E' \r\n '::text), 'description'),
    ('description', pg_catalog.to_jsonb(pg_catalog.repeat('d', 9)), 'description'), ('description', pg_catalog.to_jsonb(pg_catalog.repeat('d', 2001)), 'description'),
    ('city', 'null'::jsonb, 'city'), ('city', pg_catalog.to_jsonb(E' \t '::text), 'city'),
    ('city', pg_catalog.to_jsonb('x'::text), 'city'), ('city', pg_catalog.to_jsonb(pg_catalog.repeat('c', 101)), 'city'),
    ('address', 'null'::jsonb, 'address'), ('address', pg_catalog.to_jsonb(E' \n '::text), 'address'),
    ('address', pg_catalog.to_jsonb(pg_catalog.repeat('a', 4)), 'address'), ('address', pg_catalog.to_jsonb(pg_catalog.repeat('a', 501)), 'address'),
    ('category_id', 'null'::jsonb, 'category'),
    ('category_id', pg_catalog.to_jsonb(pg_catalog.gen_random_uuid()), 'category'),
    ('category_id', pg_catalog.to_jsonb(pg_catalog.current_setting('request_test.inactive')), 'category'),
    ('preferred_at', pg_catalog.to_jsonb(pg_catalog.clock_timestamp()), 'preferred_time'),
    ('preferred_at', pg_catalog.to_jsonb(pg_catalog.clock_timestamp() - interval '1 day'), 'preferred_time'),
    ('preferred_at', pg_catalog.to_jsonb(pg_catalog.clock_timestamp() + interval '4321 hours'), 'preferred_time'),
    ('preferred_at', '"infinity"'::jsonb, 'preferred_time'), ('preferred_at', '"-infinity"'::jsonb, 'preferred_time'),
    ('consent', 'false'::jsonb, 'consent'), ('consent', 'null'::jsonb, 'consent')
  ) as payload(field, value, error_key) loop
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
      pg_catalog.jsonb_build_object(invalid.field, invalid.value)), 'P0001', 'requests.errors.' || invalid.error_key);
    perform pg_temp.request_assert(public.get_service_request(request_id) is null,
      'invalid ' || invalid.field || ' leaves no partially published request');
  end loop;
  perform pg_temp.request_expect_error(pg_catalog.format(
    'select public.submit_service_request(%L,%L,''Valid title'',''Valid description'',''Cairo'',''Valid address'',null,null,true)',
    request_id, pg_catalog.current_setting('request_test.active')), 'P0001', 'requests.errors.photos');

  foreach relation_name in array array['public.service_requests', 'public.service_request_photos'] loop
    perform pg_temp.request_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.request_expect_error('update ' || relation_name || ' set id = id', '42501');
    perform pg_temp.request_expect_error('delete from ' || relation_name, '42501');
  end loop;
  perform pg_temp.request_expect_error('update public.profiles set role = ''provider'' where id = auth.uid()', '42501');
  perform pg_temp.request_expect_error('select salahly_private.service_request_snapshot(null)', '42501');
  perform pg_temp.request_expect_error('select salahly_private.lock_request_customer(auth.uid())', '42501');

  execute pg_temp.request_submit_sql(pg_catalog.gen_random_uuid(), pg_catalog.jsonb_build_object(
    'title', pg_catalog.repeat('t', 5), 'description', pg_catalog.repeat('d', 10),
    'city', 'AA', 'address', pg_catalog.repeat('a', 5), 'preferred_at', pg_catalog.clock_timestamp() + interval '1 minute'
  )) into result;
  perform pg_temp.request_assert(pg_catalog.char_length(result ->> 'title') = 5
    and pg_catalog.char_length(result ->> 'description') = 10 and pg_catalog.char_length(result ->> 'city') = 2
    and pg_catalog.char_length(result ->> 'address') = 5 and result -> 'preferred_at' <> 'null'::jsonb,
    'all minimum text bounds and a future preferred instant are accepted');
  changes := pg_catalog.jsonb_build_object('title', pg_catalog.repeat('t', 120), 'description', pg_catalog.repeat('d', 2000),
    'city', pg_catalog.repeat('c', 100), 'address', pg_catalog.repeat('a', 500),
    'preferred_at', pg_catalog.clock_timestamp() + interval '4320 hours');
  execute pg_temp.request_submit_sql(pg_catalog.gen_random_uuid(), changes) into result;
  perform pg_temp.request_assert(pg_catalog.char_length(result ->> 'title') = 120
    and pg_catalog.char_length(result ->> 'description') = 2000 and pg_catalog.char_length(result ->> 'city') = 100
    and pg_catalog.char_length(result ->> 'address') = 500
    and (result ->> 'preferred_at')::timestamptz <= (result ->> 'created_at')::timestamptz + interval '4320 hours',
    'all upper text bounds and at-most-180-day preferred instant are accepted');
end;
$validation$;

do $zero_photos$
declare
  request_id uuid := pg_catalog.current_setting('request_test.zero')::uuid;
  result jsonb;
  retry jsonb;
begin
  execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object(
    'title', E' \tRepair kitchen pipe\n ', 'description', E' \rThe kitchen pipe leaks when the tap is running.\t',
    'city', E' \nCairo\t ', 'address', E' \t12 Example Street, apartment 4\n '
  )) into result;
  execute pg_temp.request_submit_sql(request_id) into retry;
  perform pg_temp.request_assert(result = retry and result ->> 'customer_id' = auth.uid()::text
    and result ->> 'title' = 'Repair kitchen pipe' and result ->> 'description' = 'The kitchen pipe leaks when the tap is running.'
    and result ->> 'city' = 'Cairo' and result ->> 'address' = '12 Example Street, apartment 4'
    and result -> 'preferred_at' = 'null'::jsonb and result -> 'photos' = '[]'::jsonb
    and result ->> 'status' = 'open' and result -> 'cancelled_at' = 'null'::jsonb
    and result -> 'consented_at' = result -> 'created_at',
    'zero-photo submission trims all fields, stamps consent, and is stably idempotent');
  perform pg_temp.request_assert(result ->> 'category_name_en' = 'Original category EN'
    and result ->> 'category_name_ar' = 'Original category AR' and result ->> 'category_icon_key' = 'plumbing'
    and public.get_service_request(request_id) = result
    and (select pg_catalog.count(*) from public.service_requests where id = request_id) = 1,
    'canonical server-derived snapshots/get agree without duplicate zero-photo rows');
  perform pg_catalog.set_config('request_test.zero_snapshot', result::text, true);
end;
$zero_photos$;

do $photo_payload_validation$
declare
  request_id uuid := pg_catalog.gen_random_uuid();
  photo jsonb := pg_temp.request_photo(request_id);
  invalid record;
  value jsonb;
  invalid_path text;
begin
  for value in select item from pg_catalog.jsonb_array_elements(
    '[null,{},true,0,"[]",[null],[1],[[]],[{}]]'::jsonb
  ) as invalid(item) loop
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
      pg_catalog.jsonb_build_object('photos', value)), 'P0001', 'requests.errors.photos');
  end loop;
  for invalid in select * from (values
    (photo - 'id', 'photos'), (photo - 'storage_path', 'photos'), (photo - 'mime_type', 'photos'), (photo - 'size_bytes', 'photos'),
    (photo || '{"position":1}'::jsonb, 'photos'), (photo || '{"object_id":"forged"}'::jsonb, 'photos'),
    (photo || '{"customer_id":"forged"}'::jsonb, 'photos'), (photo || '{"id":null}'::jsonb, 'photos'),
    (photo || '{"id":1}'::jsonb, 'photos'), (photo || '{"id":"not-a-uuid"}'::jsonb, 'photos'),
    (photo || '{"id":"00000000-0000-0000-0000-000000000000"}'::jsonb, 'photos'),
    (photo || '{"id":"10000000-0000-1000-8000-000000000000"}'::jsonb, 'photos'),
    (photo || '{"id":"10000000-0000-4000-7000-000000000000"}'::jsonb, 'photos'),
    (photo || '{"storage_path":null}'::jsonb, 'photos'), (photo || '{"storage_path":[]}'::jsonb, 'photos'),
    (photo || '{"mime_type":null}'::jsonb, 'photo_type'), (photo || '{"mime_type":1}'::jsonb, 'photo_type'),
    (photo || '{"mime_type":"application/pdf"}'::jsonb, 'photo_type'), (photo || '{"mime_type":"IMAGE/JPEG"}'::jsonb, 'photo_type'),
    (photo || '{"mime_type":"image/jpeg; charset=utf-8"}'::jsonb, 'photo_type'),
    (photo || '{"size_bytes":null}'::jsonb, 'photo_size'), (photo || '{"size_bytes":"1"}'::jsonb, 'photo_size'),
    (photo || '{"size_bytes":0}'::jsonb, 'photo_size'), (photo || '{"size_bytes":-1}'::jsonb, 'photo_size'),
    (photo || '{"size_bytes":5242881}'::jsonb, 'photo_size'), (photo || '{"size_bytes":1.5}'::jsonb, 'photo_size'),
    (photo || '{"size_bytes":1e100}'::jsonb, 'photo_size'), (photo || '{"size_bytes":true}'::jsonb, 'photo_size'),
    (photo || '{"size_bytes":[]}'::jsonb, 'photo_size'), (photo || '{"size_bytes":{}}'::jsonb, 'photo_size')
  ) as payload(photo, error_key) loop
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
      pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(invalid.photo))),
      'P0001', 'requests.errors.' || invalid.error_key);
  end loop;
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photo, photo))), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(
      photo, pg_temp.request_photo(request_id), pg_temp.request_photo(request_id), pg_temp.request_photo(request_id)
    ))), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photo))), 'P0001', 'requests.errors.photos');

  foreach invalid_path in array array[
    pg_catalog.replace(photo ->> 'storage_path', auth.uid()::text, pg_catalog.current_setting('request_test.b')),
    pg_catalog.replace(photo ->> 'storage_path', request_id::text, pg_catalog.gen_random_uuid()::text),
    pg_catalog.replace(photo ->> 'storage_path', photo ->> 'id', pg_catalog.gen_random_uuid()::text),
    pg_catalog.replace(photo ->> 'storage_path', '.jpg', '.png'),
    pg_catalog.replace(photo ->> 'storage_path', '.jpg', '.jpeg'),
    pg_catalog.upper(photo ->> 'storage_path'), (photo ->> 'storage_path') || E'\n',
    ' ' || (photo ->> 'storage_path'), 'https://example.invalid/' || (photo ->> 'storage_path'),
    pg_catalog.replace(photo ->> 'storage_path', '/', '//'),
    pg_catalog.replace(photo ->> 'storage_path', '/', '/../'),
    pg_catalog.replace(photo ->> 'storage_path', '/', '/%2e%2e%2f'), ''
  ] loop
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos',
      pg_catalog.jsonb_build_array(photo || pg_catalog.jsonb_build_object('storage_path', invalid_path)))),
      'P0001', 'requests.errors.photos');
  end loop;
  perform pg_temp.request_assert(public.get_service_request(request_id) is null
    and not exists (select 1 from public.service_request_photos),
    'invalid JSON, extra fields, duplicate IDs, count/type/size/path failures leave no partial records');
end;
$photo_payload_validation$;

do $storage_boundaries$
declare
  request_id uuid := pg_catalog.gen_random_uuid();
  photo jsonb := pg_temp.request_photo(request_id);
  path text;
  invalid record;
  affected integer;
begin
  perform pg_temp.request_assert(not exists (select 1 from storage.objects where bucket_id = 'request-photos'),
    'malicious permissive Storage policy cannot expose the other customer photo');
  delete from storage.objects where bucket_id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'cross-customer cleanup is filtered despite permissive policy');
  for path in select value from pg_catalog.unnest(array[
    auth.uid()::text || '/photo.jpg', auth.uid()::text || '/' || request_id::text || '/photo.jpg',
    pg_catalog.replace(photo ->> 'storage_path', '/', '//'),
    pg_catalog.replace(photo ->> 'storage_path', '/', '/../'),
    pg_catalog.replace(photo ->> 'storage_path', '/', '/%2e%2e%2f'),
    pg_catalog.replace(photo ->> 'storage_path', request_id::text, '10000000-0000-1000-8000-000000000000'),
    pg_catalog.replace(photo ->> 'storage_path', photo ->> 'id', '10000000-0000-4000-7000-000000000000'),
    pg_catalog.replace(photo ->> 'storage_path', '.jpg', '.jpeg'),
    pg_catalog.replace(photo ->> 'storage_path', '.jpg', '.PNG'),
    pg_catalog.replace(photo ->> 'storage_path', '.jpg', '.pdf'),
    pg_catalog.upper(photo ->> 'storage_path'), (photo ->> 'storage_path') || '/extra',
    (photo ->> 'storage_path') || E'\n', ' ' || (photo ->> 'storage_path'),
    'https://example.invalid/' || (photo ->> 'storage_path'), ''
  ]) as invalid_path(value) loop
    perform pg_temp.request_expect_error(pg_catalog.format(
      'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)', path, auth.uid()),
      'P0001', 'requests.errors.photos');
  end loop;
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)',
    pg_catalog.replace(photo ->> 'storage_path', auth.uid()::text, pg_catalog.current_setting('request_test.b')),
    pg_catalog.current_setting('request_test.b')), '42501');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)',
    photo ->> 'storage_path', pg_catalog.current_setting('request_test.b')), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner) values (''request-photos'',%L,%L)',
    photo ->> 'storage_path', auth.uid()), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id,owner) values (''request-photos'',%L,%L,%L)',
    photo ->> 'storage_path', auth.uid(), pg_catalog.current_setting('request_test.b')), 'P0001', 'requests.errors.photos');

  for invalid in select * from (values
    ('null'::jsonb, 'photo_type'), ('42'::jsonb, 'photo_type'),
    ('{"mimetype":null,"size":1}'::jsonb, 'photo_type'), ('{"mimetype":1,"size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/png","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"application/pdf","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/jpeg; charset=utf-8","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"IMAGE/JPEG","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/jpeg"}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":null}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":"1"}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":0}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":-1}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":5242881}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":1.5}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":1e100}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":true}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":[]}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":{}}'::jsonb, 'photo_size')
  ) as fixture(metadata, error_key) loop
    perform pg_temp.request_expect_error(pg_catalog.format(
      'insert into storage.objects(bucket_id,name,owner_id,metadata,user_metadata) values (''request-photos'',%L,%L,%L::jsonb,''{"mimetype":"image/jpeg","size":1}''::jsonb)',
      photo ->> 'storage_path', auth.uid(), invalid.metadata), 'P0001', 'requests.errors.' || invalid.error_key);
  end loop;

  -- Metadata-less INSERT preflights are allowed, but cannot publish as photos.
  insert into storage.objects (bucket_id, name, owner_id) values ('request-photos', photo ->> 'storage_path', auth.uid()::text);
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photo))), 'P0001', 'requests.errors.photo_type');
  delete from storage.objects where bucket_id = 'request-photos' and name = photo ->> 'storage_path';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'unreferenced metadata-less permission probe can be cleaned up');
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('request-photos', photo ->> 'storage_path', auth.uid()::text, '{}'::jsonb);
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photo))), 'P0001', 'requests.errors.photo_type');
  delete from storage.objects where bucket_id = 'request-photos' and name = photo ->> 'storage_path';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'empty metadata also cannot publish and remains safely cleanable');

  update storage.buckets set public = true, file_size_limit = 99999999, allowed_mime_types = null where id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'broad policies cannot expose bucket or relax upload limits');
  delete from storage.buckets where id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'client cannot delete request bucket');
  perform pg_temp.request_expect_error('insert into storage.buckets(id,name,public) values (''request-photos'',''forged'',true)', '42501');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'update storage.buckets set id = ''request-photos'' where id = %L',
    pg_catalog.current_setting('request_test.other_bucket')), '42501');
end;
$storage_boundaries$;

-- Simulate pre-existing/trusted malformed objects to independently test RPC
-- revalidation. Only this feature's trigger is disabled while postgres inserts
-- rollback-only fixtures; it is restored BEFORE any client operation. The DDL
-- holds the table lock, so no other session can use this temporary bypass.
set local role postgres;
create temporary table request_test_legacy_objects (request_id uuid, photo jsonb, error_key text) on commit drop;
grant select on request_test_legacy_objects to authenticated;
alter table storage.objects disable trigger salahly_request_photo_guard;
do $legacy_objects$
declare
  customer uuid := pg_catalog.current_setting('request_test.a')::uuid;
  request_id uuid;
  photo jsonb;
  invalid record;
begin
  for invalid in select * from (values
    (null::jsonb, 'photo_type'), ('{}'::jsonb, 'photo_type'), ('42'::jsonb, 'photo_type'),
    ('{"mimetype":null,"size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/png","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"application/pdf","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/jpeg; charset=utf-8","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"IMAGE/JPEG","size":1}'::jsonb, 'photo_type'),
    ('{"mimetype":"image/jpeg"}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":null}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":"1"}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":0}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":-1}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":5242881}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":1.5}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":1e100}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":true}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":[]}'::jsonb, 'photo_size'),
    ('{"mimetype":"image/jpeg","size":{}}'::jsonb, 'photo_size')
  ) as fixture(metadata, error_key) loop
    request_id := pg_catalog.gen_random_uuid();
    photo := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(), 'image/jpeg', 1, customer);
    insert into storage.objects (bucket_id, name, owner_id, metadata, user_metadata)
      values ('request-photos', photo ->> 'storage_path', customer::text, invalid.metadata,
        '{"mimetype":"image/jpeg","size":1}'::jsonb);
    insert into pg_temp.request_test_legacy_objects values (request_id, photo, invalid.error_key);
  end loop;
  request_id := pg_catalog.gen_random_uuid();
  photo := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(), 'image/jpeg', 1, customer);
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('request-photos', photo ->> 'storage_path', pg_catalog.current_setting('request_test.b'),
      '{"mimetype":"image/jpeg","size":1}'::jsonb);
  insert into pg_temp.request_test_legacy_objects values (request_id, photo, 'photos');
  request_id := pg_catalog.gen_random_uuid();
  photo := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(), 'image/jpeg', 1, customer);
  insert into storage.objects (bucket_id, name, owner_id, owner, metadata)
    values ('request-photos', photo ->> 'storage_path', customer::text, pg_catalog.current_setting('request_test.b')::uuid,
      '{"mimetype":"image/jpeg","size":1}'::jsonb);
  insert into pg_temp.request_test_legacy_objects values (request_id, photo, 'photos');
  request_id := pg_catalog.gen_random_uuid();
  photo := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(), 'image/jpeg', 1, customer);
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values (pg_catalog.current_setting('request_test.other_bucket'), photo ->> 'storage_path', customer::text,
      '{"mimetype":"image/jpeg","size":1}'::jsonb);
  insert into pg_temp.request_test_legacy_objects values (request_id, photo, 'photos');
end;
$legacy_objects$;
alter table storage.objects enable trigger salahly_request_photo_guard;
set local role authenticated;
do $legacy_revalidation$
declare
  invalid record;
begin
  for invalid in select * from pg_temp.request_test_legacy_objects loop
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(invalid.request_id,
      pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(invalid.photo))),
      'P0001', 'requests.errors.' || invalid.error_key);
    perform pg_temp.request_assert(public.get_service_request(invalid.request_id) is null,
      'RPC independently rechecks finalized MIME/size/owners/bucket; user_metadata cannot repair them');
  end loop;
end;
$legacy_revalidation$;

do $multiple_photos$
declare
  request_id uuid := pg_catalog.current_setting('request_test.multi')::uuid;
  photos jsonb := '[]'::jsonb;
  photo jsonb;
  orphan jsonb;
  result jsonb;
  retry jsonb;
  index_number integer;
  affected integer;
  copy_request uuid := pg_catalog.gen_random_uuid();
  copied_photo jsonb;
begin
  for index_number in 1..3 loop
    photo := pg_temp.request_photo(request_id, pg_catalog.gen_random_uuid(),
      case when index_number = 2 then 'image/png' else 'image/jpeg' end,
      case when index_number = 2 then 5242880 when index_number = 3 then 1234 else 1 end);
    insert into storage.objects (bucket_id, name, owner_id, owner, metadata)
      values ('request-photos', photo ->> 'storage_path', auth.uid()::text,
        case when index_number = 1 then auth.uid() else null end,
        pg_catalog.jsonb_build_object('mimetype', photo ->> 'mime_type', 'size', photo -> 'size_bytes'));
    photos := photos || pg_catalog.jsonb_build_array(photo);
  end loop;
  orphan := pg_temp.request_photo(request_id);
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('request-photos', orphan ->> 'storage_path', auth.uid()::text, '{"mimetype":"image/jpeg","size":1}'::jsonb);
  perform pg_catalog.set_config('request_test.orphan', orphan::text, true);
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', photos || pg_catalog.jsonb_build_array(orphan))), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos',
    pg_catalog.jsonb_build_array(photos -> 0, photos -> 1, pg_temp.request_photo(request_id)))), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos',
    pg_catalog.jsonb_set(photos, '{2,size_bytes}', '1235'::jsonb))), 'P0001', 'requests.errors.photo_size');
  perform pg_temp.request_assert(public.get_service_request(request_id) is null
    and not exists (select 1 from public.service_request_photos)
    and (select pg_catalog.count(*) from storage.objects where bucket_id = 'request-photos'
      and pg_catalog.split_part(name, '/', 2) = request_id::text) = 4,
    'fourth/missing/mismatched photos cannot partially publish or destroy uploaded objects');

  update storage.objects set metadata = '{}'::jsonb where bucket_id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'restrictive UPDATE gate defeats broad permissive ALL policy');
  update storage.objects set bucket_id = pg_catalog.current_setting('request_test.other_bucket'), name = 'moved',
    owner_id = pg_catalog.current_setting('request_test.b') where bucket_id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'client cannot move, rename, or transfer even unreferenced uploads');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'update storage.objects set bucket_id = ''request-photos'' where bucket_id = %L and name = ''unrelated-object''',
    pg_catalog.current_setting('request_test.other_bucket')), 'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(id,bucket_id,name,owner_id) select id,bucket_id,name,owner_id from storage.objects where bucket_id = ''request-photos'' and name = %L on conflict (id) do update set metadata = ''{}''::jsonb',
    photos #>> '{0,storage_path}'), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L) on conflict (bucket_id,name) do update set owner_id = excluded.owner_id',
    photos #>> '{0,storage_path}', auth.uid()), 'P0001', 'requests.errors.photos');

  execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos', photos)) into result;
  execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos', photos)) into retry;
  perform pg_temp.request_assert(result = retry and result -> 'photos' = pg_catalog.jsonb_build_array(
    (photos -> 0) || '{"position":1}'::jsonb, (photos -> 1) || '{"position":2}'::jsonb, (photos -> 2) || '{"position":3}'::jsonb
  ) and result ->> 'status' = 'open' and result -> 'consented_at' = result -> 'created_at',
    'three JPEG/PNG photos at inclusive size bounds publish in client order and retry identically');
  execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos',
    pg_catalog.jsonb_set(photos, '{0,id}', pg_catalog.to_jsonb(pg_catalog.upper(photos #>> '{0,id}'))))) into retry;
  perform pg_temp.request_assert(retry = result, 'photo IDs normalize as UUIDs while storage paths stay exact');
  perform pg_temp.request_assert(public.get_service_request(request_id) = result
    and (select pg_catalog.count(*) from public.service_request_photos) = 3
    and (select id from public.service_requests order by created_at desc, id desc limit 1) = request_id
    and not exists (select 1 from public.service_requests where customer_id <> auth.uid())
    and not exists (select 1 from public.service_request_photos as link where link.request_id <> (result ->> 'id')::uuid),
    'owned history/detail and photo-table SELECT support ordered embedding without foreign rows');
  perform pg_catalog.set_config('request_test.photos', photos::text, true);
  perform pg_catalog.set_config('request_test.multi_snapshot', result::text, true);
  delete from storage.objects where bucket_id = 'request-photos' and name in (
    photos #>> '{0,storage_path}', photos #>> '{1,storage_path}', photos #>> '{2,storage_path}');
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'published photo objects cannot be owner cleanup');

  copied_photo := pg_temp.request_photo(copy_request, (photos #>> '{0,id}')::uuid);
  insert into storage.objects (bucket_id, name, owner_id, metadata)
    values ('request-photos', copied_photo ->> 'storage_path', auth.uid()::text, '{"mimetype":"image/jpeg","size":1}'::jsonb);
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(copy_request,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(copied_photo))), 'P0001', 'requests.errors.photos');
  perform pg_temp.request_assert(public.get_service_request(copy_request) is null
    and public.get_service_request(request_id) = result, 'globally duplicated photo ID rolls back the entire new request');
  delete from storage.objects where bucket_id = 'request-photos' and name = copied_photo ->> 'storage_path';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'a rejected duplicate-ID upload remains unreferenced and cleanable');
end;
$multiple_photos$;

do $idempotency_conflicts$
declare
  request_id uuid;
  photos jsonb;
  snapshot jsonb;
  retry jsonb;
  changes jsonb;
begin
  foreach request_id in array array[
    pg_catalog.current_setting('request_test.zero')::uuid, pg_catalog.current_setting('request_test.multi')::uuid
  ] loop
    photos := case when request_id = pg_catalog.current_setting('request_test.zero')::uuid then '[]'::jsonb
      else pg_catalog.current_setting('request_test.photos')::jsonb end;
    snapshot := public.get_service_request(request_id);
    for changes in select value from pg_catalog.jsonb_array_elements(pg_catalog.jsonb_build_array(
      '{"title":"Different title"}'::jsonb, '{"title":null}'::jsonb,
      '{"description":"Changed original description"}'::jsonb, '{"description":"short"}'::jsonb,
      '{"city":"Giza"}'::jsonb, '{"city":""}'::jsonb,
      '{"address":"Another address"}'::jsonb, '{"address":null}'::jsonb,
      pg_catalog.jsonb_build_object('category_id', pg_catalog.current_setting('request_test.inactive')),
      '{"category_id":null}'::jsonb,
      pg_catalog.jsonb_build_object('preferred_at', pg_catalog.clock_timestamp() - interval '1 day'),
      '{"photos":null}'::jsonb, '{"photos":{}}'::jsonb,
      pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(pg_temp.request_photo(request_id)))
    )) loop
      perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
        pg_catalog.jsonb_build_object('photos', photos) || changes), 'P0001', 'requests.errors.conflict');
      perform pg_temp.request_assert(public.get_service_request(request_id) = snapshot,
        'mismatched duplicate cannot modify original fields, consent, timestamps, or photos');
    end loop;
    perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
      pg_catalog.jsonb_build_object('photos', photos, 'consent', false)), 'P0001', 'requests.errors.consent');
    execute pg_temp.request_submit_sql(request_id, pg_catalog.jsonb_build_object('photos', photos)) into retry;
    perform pg_temp.request_assert(retry = snapshot, 'valid exact retry still works after rejected duplicates');
  end loop;
  request_id := pg_catalog.current_setting('request_test.multi')::uuid;
  photos := pg_catalog.current_setting('request_test.photos')::jsonb;
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', '[]'::jsonb)), 'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(photos -> 2, photos -> 1, photos -> 0))),
    'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(request_id,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_set(photos, '{0,size_bytes}', '2'::jsonb))),
    'P0001', 'requests.errors.conflict');
end;
$idempotency_conflicts$;

set local role postgres;
do $historical_fixture$
declare
  historical jsonb;
  created timestamptz := pg_catalog.clock_timestamp() - interval '2 days';
begin
  -- A trusted historical fixture simulates elapsed time without sleeping or
  -- mutating the immutable content of a newly submitted record.
  select pg_catalog.to_jsonb(request) into historical from public.service_requests as request
    where id = pg_catalog.current_setting('request_test.zero')::uuid;
  historical := historical || pg_catalog.jsonb_build_object('id', pg_catalog.current_setting('request_test.past'),
    'created_at', created, 'consented_at', created, 'preferred_at', created + interval '1 day');
  insert into public.service_requests select * from pg_catalog.jsonb_populate_record(null::public.service_requests, historical);
  perform pg_catalog.set_config('request_test.past_preferred', (created + interval '1 day')::text, true);
end;
$historical_fixture$;
update public.service_categories set is_active = false, name_en = 'Changed EN', name_ar = 'Changed AR', icon_key = 'painting'
  where id = pg_catalog.current_setting('request_test.active')::uuid;
set local role authenticated;
do $history_and_cancel$
declare
  zero_id uuid := pg_catalog.current_setting('request_test.zero')::uuid;
  multi_id uuid := pg_catalog.current_setting('request_test.multi')::uuid;
  past_id uuid := pg_catalog.current_setting('request_test.past')::uuid;
  photos jsonb := pg_catalog.current_setting('request_test.photos')::jsonb;
  result jsonb;
  retry jsonb;
  affected integer;
begin
  perform pg_temp.request_assert(not exists (select 1 from public.service_categories
    where id = pg_catalog.current_setting('request_test.active')::uuid)
    and public.get_service_request(zero_id) = pg_catalog.current_setting('request_test.zero_snapshot')::jsonb
    and public.get_service_request(multi_id) = pg_catalog.current_setting('request_test.multi_snapshot')::jsonb,
    'deactivated/renamed catalog stays hidden but owned history retains original display snapshots');
  execute pg_temp.request_submit_sql(zero_id) into result;
  perform pg_temp.request_assert(result = pg_catalog.current_setting('request_test.zero_snapshot')::jsonb,
    'zero-photo ID retry bypasses current category activity and catalog display changes');
  execute pg_temp.request_submit_sql(multi_id, pg_catalog.jsonb_build_object('photos', photos)) into result;
  perform pg_temp.request_assert(result = pg_catalog.current_setting('request_test.multi_snapshot')::jsonb,
    'multi-photo ID retry also bypasses current catalog validation');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.gen_random_uuid()), 'P0001', 'requests.errors.category');
  execute pg_temp.request_submit_sql(past_id, pg_catalog.jsonb_build_object(
    'preferred_at', pg_catalog.current_setting('request_test.past_preferred'))) into result;
  perform pg_temp.request_assert(result ->> 'status' = 'open'
    and (result ->> 'preferred_at')::timestamptz < pg_catalog.clock_timestamp(),
    'an originally valid now-past preferred instant does not break historical ID idempotency');
  result := public.cancel_service_request(past_id);
  execute pg_temp.request_submit_sql(past_id, pg_catalog.jsonb_build_object(
    'preferred_at', pg_catalog.current_setting('request_test.past_preferred'))) into retry;
  perform pg_temp.request_assert(result = retry and result ->> 'status' = 'cancelled',
    'cancelled historical request with past preference/inactive category retries without reopening');

  result := public.cancel_service_request(multi_id);
  retry := public.cancel_service_request(multi_id);
  perform pg_temp.request_assert(result = retry and result ->> 'status' = 'cancelled'
    and (result ->> 'cancelled_at')::timestamptz >= (result ->> 'created_at')::timestamptz
    and (result - array['status', 'cancelled_at']) =
      (pg_catalog.current_setting('request_test.multi_snapshot')::jsonb - array['status', 'cancelled_at']),
    'cancellation changes only status/time; repeat cancellation retains exact time and all evidence');
  execute pg_temp.request_submit_sql(multi_id, pg_catalog.jsonb_build_object('photos', photos)) into retry;
  perform pg_temp.request_assert(retry = result and public.get_service_request(multi_id) = result,
    'submit retry and get return cancelled canonical state, never a new/open request');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(multi_id,
    pg_catalog.jsonb_build_object('photos', photos, 'title', 'Changed after cancellation')), 'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set status = ''open'', cancelled_at = null where id = %L',
    multi_id), '42501');
  perform pg_temp.request_expect_error('update public.service_requests set customer_id = auth.uid(), category_name_en = ''forged'', consented_at = now()', '42501');
  perform pg_temp.request_expect_error('update public.service_request_photos set position = 3', '42501');
  perform pg_temp.request_expect_error('delete from public.service_request_photos', '42501');
  delete from storage.objects where bucket_id = 'request-photos' and name in (
    photos #>> '{0,storage_path}', photos #>> '{1,storage_path}', photos #>> '{2,storage_path}');
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'cancelled photo evidence remains private and cannot be cleaned up');
  perform pg_temp.request_assert((select pg_catalog.count(*) from storage.objects where bucket_id = 'request-photos' and name in (
    photos #>> '{0,storage_path}', photos #>> '{1,storage_path}', photos #>> '{2,storage_path}')) = 3,
    'owner can still privately download all cancelled evidence');
  delete from storage.objects where bucket_id = 'request-photos'
    and name = pg_catalog.current_setting('request_test.orphan')::jsonb ->> 'storage_path';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'unreferenced upload cleanup remains allowed after cancellation');
  perform pg_catalog.set_config('request_test.cancelled_snapshot', result::text, true);
end;
$history_and_cancel$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $trusted_storage$
declare
  path text := pg_catalog.current_setting('request_test.photos')::jsonb #>> '{0,storage_path}';
  statement_text text;
begin
  perform pg_temp.request_assert((select pg_catalog.count(*) from public.service_request_photos where request_id in (
    pg_catalog.current_setting('request_test.multi')::uuid, pg_catalog.current_setting('request_test.b_request')::uuid)) = 4,
    'trusted service role can read audit rows across customers, but cannot mutate them directly');
  perform pg_temp.request_expect_error('update public.service_requests set status = ''open''', '42501');
  perform pg_temp.request_expect_error('delete from public.service_request_photos', '42501');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.get_service_request(%L)',
    pg_catalog.current_setting('request_test.multi')), '42501');
  perform pg_temp.request_expect_error(pg_catalog.format('delete from storage.objects where bucket_id = ''request-photos'' and name = %L', path),
    'P0001', 'requests.errors.status');
  foreach statement_text in array array[
    'metadata = ''{"mimetype":"image/jpeg","size":2}''::jsonb',
    'user_metadata = ''{"replacement":true}''::jsonb', 'version = ''replacement''',
    'name = ''replacement.jpg''', 'bucket_id = ' || pg_catalog.quote_literal(pg_catalog.current_setting('request_test.other_bucket')),
    'owner_id = ' || pg_catalog.quote_literal(pg_catalog.current_setting('request_test.b')),
    'owner = ' || pg_catalog.quote_literal(pg_catalog.current_setting('request_test.b')) || '::uuid',
    'id = pg_catalog.gen_random_uuid()', 'created_at = pg_catalog.clock_timestamp()'
  ] loop
    perform pg_temp.request_expect_error(pg_catalog.format(
      'update storage.objects set %s where bucket_id = ''request-photos'' and name = %L', statement_text, path),
      'P0001', 'requests.errors.status');
  end loop;
  update storage.objects set last_accessed_at = '2026-10-31T00:00:00Z'::timestamptz, updated_at = pg_catalog.clock_timestamp()
    where bucket_id = 'request-photos' and name = path;
  perform pg_temp.request_assert(exists (select 1 from storage.objects where bucket_id = 'request-photos' and name = path
    and last_accessed_at = '2026-10-31T00:00:00Z'::timestamptz),
    'trusted access timestamp updates work with generated path_tokens and preserve content');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'update storage.objects set bucket_id = ''request-photos'' where bucket_id = %L and name = ''unrelated-object''',
    pg_catalog.current_setting('request_test.other_bucket')), 'P0001', 'requests.errors.status');
end;
$trusted_storage$;

set local role postgres;
do $record_constraints$
declare
  original jsonb;
  invalid jsonb;
  changed jsonb;
  photo jsonb;
  multi_id uuid := pg_catalog.current_setting('request_test.multi')::uuid;
  zero_id uuid := pg_catalog.current_setting('request_test.zero')::uuid;
begin
  select pg_catalog.to_jsonb(request) into original from public.service_requests as request where id = zero_id;
  for invalid in select value from pg_catalog.jsonb_array_elements(pg_catalog.jsonb_build_array(
    '{"id":"10000000-0000-1000-8000-000000000000"}'::jsonb,
    '{"title":" Tiny "}'::jsonb, '{"title":"1234"}'::jsonb,
    pg_catalog.jsonb_build_object('title', pg_catalog.repeat('t', 121)),
    '{"description":"too short"}'::jsonb, pg_catalog.jsonb_build_object('description', pg_catalog.repeat('d', 2001)),
    '{"description":" Untrimmed description "}'::jsonb,
    '{"city":"x"}'::jsonb, '{"city":" Cairo "}'::jsonb, pg_catalog.jsonb_build_object('city', pg_catalog.repeat('c', 101)),
    '{"address":"1234"}'::jsonb, '{"address":" Untrimmed address "}'::jsonb,
    pg_catalog.jsonb_build_object('address', pg_catalog.repeat('a', 501)),
    '{"status":"booked"}'::jsonb, '{"status":"cancelled","cancelled_at":null}'::jsonb,
    pg_catalog.jsonb_build_object('status', 'open', 'cancelled_at', pg_catalog.clock_timestamp()),
    pg_catalog.jsonb_build_object('status', 'cancelled', 'cancelled_at', (original ->> 'created_at')::timestamptz - interval '1 second'),
    '{"status":"cancelled","cancelled_at":"infinity"}'::jsonb,
    pg_catalog.jsonb_build_object('consented_at', (original ->> 'created_at')::timestamptz - interval '1 second'),
    '{"created_at":"infinity","consented_at":"infinity"}'::jsonb,
    pg_catalog.jsonb_build_object('preferred_at', original -> 'created_at'),
    pg_catalog.jsonb_build_object('preferred_at', (original ->> 'created_at')::timestamptz + interval '4321 hours'),
    '{"preferred_at":"infinity"}'::jsonb
  )) loop
    changed := original || pg_catalog.jsonb_build_object('id', pg_catalog.gen_random_uuid()) || invalid;
    perform pg_temp.request_expect_error(pg_catalog.format(
      'insert into public.service_requests select * from pg_catalog.jsonb_populate_record(null::public.service_requests,%L::jsonb)', changed), '23514');
  end loop;
  select pg_catalog.to_jsonb(link) into photo from public.service_request_photos as link where link.request_id = multi_id order by position limit 1;
  for invalid in select value from pg_catalog.jsonb_array_elements('[
    {"id":"10000000-0000-1000-8000-000000000000"},
    {"position":0},{"position":4},{"size_bytes":0},{"size_bytes":5242881},
    {"storage_path":"forged.jpg"},{"mime_type":"application/pdf"},{"mime_type":"image/png"}
  ]'::jsonb) loop
    perform pg_temp.request_expect_error(pg_catalog.format(
      'insert into public.service_request_photos select * from pg_catalog.jsonb_populate_record(null::public.service_request_photos,%L::jsonb)',
      photo || invalid), '23514');
  end loop;
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into public.service_request_photos select * from public.service_request_photos where id = %L', photo ->> 'id'), '23505');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set title = ''Changed content'' where id = %L', zero_id),
    'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set category_name_en = ''Changed snapshot'' where id = %L', zero_id),
    'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set status = ''booked'' where id = %L', zero_id),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set status = ''cancelled'', cancelled_at = created_at - interval ''1 second'' where id = %L', zero_id),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set status = ''open'', cancelled_at = null where id = %L', multi_id),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_requests set cancelled_at = pg_catalog.clock_timestamp() where id = %L', multi_id),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('update public.service_request_photos set size_bytes = 2 where id = %L', photo ->> 'id'),
    'P0001', 'requests.errors.conflict');
  perform pg_temp.request_expect_error(pg_catalog.format('delete from public.service_request_photos where id = %L', photo ->> 'id'),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('delete from public.service_requests where id = %L', zero_id),
    'P0001', 'requests.errors.status');
  perform pg_temp.request_expect_error(pg_catalog.format('delete from public.profiles where id = %L',
    pg_catalog.current_setting('request_test.a')), '23001,23503');
  perform pg_temp.request_expect_error(pg_catalog.format('delete from public.service_categories where id = %L',
    pg_catalog.current_setting('request_test.active')), '23001,23503');
end;
$record_constraints$;

-- Independently prove the FK backstop, not only the trigger's visible-row check.
alter table storage.objects disable trigger salahly_request_photo_guard;
select pg_temp.request_expect_error(pg_catalog.format(
  'delete from storage.objects where bucket_id = ''request-photos'' and name = %L',
  pg_catalog.current_setting('request_test.photos')::jsonb #>> '{0,storage_path}'), '23001,23503');
alter table storage.objects enable trigger salahly_request_photo_guard;

select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('request_test.b'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('request_test.b'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $symmetric_isolation$
declare
  result jsonb;
begin
  perform pg_temp.request_assert((select pg_catalog.count(*) from public.service_requests) = 1
    and (select pg_catalog.count(*) from public.service_request_photos) = 1
    and (select pg_catalog.count(*) from storage.objects where bucket_id = 'request-photos') = 1
    and public.get_service_request(pg_catalog.current_setting('request_test.multi')::uuid) is null,
    'second customer cannot see first customer history, location, photos, or cancelled evidence');
  execute pg_temp.request_submit_sql(pg_catalog.current_setting('request_test.b_request')::uuid,
    pg_catalog.jsonb_build_object('photos', pg_catalog.jsonb_build_array(pg_catalog.current_setting('request_test.b_photo')::jsonb))) into result;
  perform pg_temp.request_assert(result = pg_catalog.current_setting('request_test.b_snapshot')::jsonb,
    'other customer request remains unchanged and idempotent after catalog deactivation');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.cancel_service_request(%L)',
    pg_catalog.current_setting('request_test.multi')), 'P0001', 'requests.errors.not_found');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.current_setting('request_test.zero')::uuid),
    'P0001', 'requests.errors.conflict');
end;
$symmetric_isolation$;

set local role postgres;
update auth.users set raw_user_meta_data = '{"role":"customer","is_admin":true}'::jsonb
  where id = pg_catalog.current_setting('request_test.provider')::uuid;
select pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.current_setting('request_test.provider'), true),
  pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object(
    'sub', pg_catalog.current_setting('request_test.provider'), 'role', 'authenticated',
    'is_admin', true, 'user_metadata', '{"role":"customer"}'::jsonb)::text, true);
set local role authenticated;
do $provider_denied$
declare
  relation_name text;
  count_visible integer;
  photo jsonb := pg_temp.request_photo(pg_catalog.gen_random_uuid());
begin
  perform pg_temp.request_assert(exists (select 1 from public.profiles where id = auth.uid() and role = 'provider')
    and exists (select 1 from public.provider_verifications where user_id = auth.uid() and status = 'verified'),
    'forged customer/admin metadata did not change the verified provider database role');
  foreach relation_name in array array['public.service_requests', 'public.service_request_photos'] loop
    execute 'select count(*) from ' || relation_name into count_visible;
    perform pg_temp.request_assert(count_visible = 0, 'verified provider has no request feed/private rows: ' || relation_name);
    perform pg_temp.request_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.request_expect_error('update ' || relation_name || ' set id = id', '42501');
    perform pg_temp.request_expect_error('delete from ' || relation_name, '42501');
  end loop;
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.gen_random_uuid()), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error('select public.get_service_request(null)', '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.get_service_request(%L)',
    pg_catalog.current_setting('request_test.multi')), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error(pg_catalog.format('select public.cancel_service_request(%L)',
    pg_catalog.current_setting('request_test.multi')), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)',
    photo ->> 'storage_path', auth.uid()), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)',
    pg_temp.request_photo(pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid(), 'image/jpeg', 1,
      pg_catalog.current_setting('request_test.a')::uuid) ->> 'storage_path',
    pg_catalog.current_setting('request_test.a')), '42501');
  perform pg_temp.request_assert(not exists (select 1 from storage.objects where bucket_id = 'request-photos'),
    'verified provider cannot download request photos despite broad permissive policies');
end;
$provider_denied$;

set local role postgres;
select pg_catalog.set_config('request.jwt.claim.sub', '', true),
  pg_catalog.set_config('request.jwt.claims', '{"role":"authenticated"}', true);
set local role authenticated;
do $missing_identity$
begin
  perform pg_temp.request_assert(auth.uid() is null and not exists (select 1 from public.service_requests)
    and not exists (select 1 from public.service_request_photos)
    and not exists (select 1 from storage.objects where bucket_id = 'request-photos'),
    'missing subject exposes no requests, addresses, or photos');
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.gen_random_uuid()), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error('select public.get_service_request(null)', '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error('select public.cancel_service_request(null)', '42501', 'requests.errors.access');
  perform pg_catalog.set_config('request.jwt.claim.sub', pg_catalog.gen_random_uuid()::text, true);
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.gen_random_uuid()), '42501', 'requests.errors.access');
  perform pg_temp.request_expect_error('select public.get_service_request(null)', '42501', 'requests.errors.access');
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
  photo jsonb := pg_temp.request_photo(pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid(), 'image/jpeg', 1,
    pg_catalog.current_setting('request_test.a')::uuid);
begin
  foreach relation_name in array array['public.service_requests', 'public.service_request_photos'] loop
    perform pg_temp.request_expect_error('select * from ' || relation_name, '42501');
    perform pg_temp.request_expect_error('insert into ' || relation_name || ' default values', '42501');
    perform pg_temp.request_expect_error('update ' || relation_name || ' set id = id', '42501');
    perform pg_temp.request_expect_error('delete from ' || relation_name, '42501');
  end loop;
  perform pg_temp.request_expect_error(pg_temp.request_submit_sql(pg_catalog.gen_random_uuid()), '42501');
  perform pg_temp.request_expect_error('select public.get_service_request(null)', '42501');
  perform pg_temp.request_expect_error('select public.cancel_service_request(null)', '42501');
  perform pg_temp.request_expect_error('select salahly_private.request_customer_is_self(null)', '42501');
  perform pg_temp.request_assert(not exists (select 1 from storage.objects where bucket_id = 'request-photos'),
    'anonymous cannot download request photos through permissive policies');
  perform pg_temp.request_expect_error(pg_catalog.format(
    'insert into storage.objects(bucket_id,name,owner_id) values (''request-photos'',%L,%L)',
    photo ->> 'storage_path', pg_catalog.current_setting('request_test.a')), '42501');
  update storage.objects set metadata = '{}'::jsonb where bucket_id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'anonymous object UPDATE stays denied');
  delete from storage.objects where bucket_id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'anonymous object DELETE stays denied');
  update storage.buckets set public = true where id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'anonymous cannot expose request bucket');
  delete from storage.buckets where id = 'request-photos';
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 0, 'anonymous cannot remove request bucket');
  perform pg_temp.request_expect_error('insert into storage.buckets(id,name) values (''request-photos'',''anonymous'')', '42501');

  perform pg_temp.request_assert(exists (select 1 from storage.objects
    where bucket_id = pg_catalog.current_setting('request_test.other_bucket') and name = 'unrelated-object'),
    'unrelated anonymous bucket SELECT remains governed by existing policies');
  insert into storage.objects (bucket_id, name, metadata)
    values (pg_catalog.current_setting('request_test.other_bucket'), unrelated_name, '{"arbitrary":true}'::jsonb);
  update storage.objects set metadata = '{"changed":true}'::jsonb
    where bucket_id = pg_catalog.current_setting('request_test.other_bucket') and name = unrelated_name;
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'unrelated anonymous Storage INSERT/UPDATE still work');
  delete from storage.objects where bucket_id = pg_catalog.current_setting('request_test.other_bucket') and name = unrelated_name;
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'unrelated anonymous Storage DELETE still works');
  update storage.buckets set public = false where id = pg_catalog.current_setting('request_test.other_bucket');
  get diagnostics affected = row_count;
  perform pg_temp.request_assert(affected = 1, 'unrelated bucket settings are not changed by M6 guards');
end;
$anonymous$;

set local role postgres;
do $complete$
begin
  perform pg_temp.request_assert((select pg_catalog.count(*) from public.service_requests where customer_id =
    pg_catalog.current_setting('request_test.a')::uuid) = 5
    and (select pg_catalog.count(*) from public.service_request_photos where request_id in (
      pg_catalog.current_setting('request_test.multi')::uuid, pg_catalog.current_setting('request_test.b_request')::uuid)) = 4,
    'failed validation/escalation attempts did not add requests or remove published evidence');
  perform pg_temp.request_assert(salahly_private.service_request_snapshot(pg_catalog.current_setting('request_test.multi')::uuid)
    = pg_catalog.current_setting('request_test.cancelled_snapshot')::jsonb,
    'cancelled request content, snapshots, consent, and exact photo links survived all attacks');
  perform pg_temp.request_assert(exists (select 1 from storage.buckets where id = 'request-photos' and not public
    and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg', 'image/png']),
    'private bucket settings survived every permissive-policy attack');
  perform pg_temp.request_assert(exists (select 1 from pg_catalog.pg_trigger
    where tgrelid = 'storage.objects'::regclass and tgname = 'salahly_request_photo_guard' and tgenabled = 'O'),
    'all temporarily bypassed fixture guards were restored');
  raise notice 'PASS: all Salahly service request authorization/Storage SQL checks passed; rolling back every fixture.';
end;
$complete$;

rollback;
