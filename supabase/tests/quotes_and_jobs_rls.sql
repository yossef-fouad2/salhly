-- Rollback-only M7 authorization, privacy, revision, and lifecycle assertions.
-- Install M1/M5/M6/M7, then run this WHOLE file as postgres on an isolated TEST
-- database. Never replace ROLLBACK with COMMIT. The final PASS notice is required.
-- Synthetic users/catalog/Storage metadata/ACL probes all roll back. Auth hooks
-- may have external effects, so do not run this against production accounts.
-- SET ROLE/JWT GUCs exercise SQL authorization, not JWT validation, hosted HTTP,
-- Storage bytes, or concurrency. Independent-session races belong to the runner.

begin;
set local search_path = '';
set local standard_conforming_strings = on;
set local timezone = 'UTC';

create temporary table marketplace_test_scope (unused boolean) on commit drop;
create function pg_temp.marketplace_assert(p_condition boolean, p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  if p_condition is distinct from true then raise exception 'FAIL: %', p_label; end if;
  raise notice 'PASS: %', p_label;
end;
$function$;

create function pg_temp.marketplace_expect_error(p_sql text, p_state text, p_message text default null)
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
    raise exception 'FAIL: expected % / %, got % / %; SQL: %', p_state, p_message, actual_state, actual_message, p_sql;
  end if;
  raise notice 'PASS (expected error): % / %', actual_state, actual_message;
end;
$function$;

create function pg_temp.marketplace_login(p_user_id uuid)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  perform pg_catalog.set_config('request.jwt.claim.sub', coalesce(p_user_id::text, ''), true);
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.jsonb_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);
end;
$function$;

create function pg_temp.marketplace_keys(p_value jsonb, p_keys text[], p_label text)
returns void language plpgsql security invoker set search_path = ''
as $function$
begin
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_typeof(p_value) = 'object'
    and p_value ?& p_keys and (p_value - p_keys) = '{}'::jsonb, p_label);
end;
$function$;

create function pg_temp.marketplace_request(p_id uuid, p_photos jsonb default '[]'::jsonb, p_preferred timestamptz default null)
returns jsonb language sql security invoker set search_path = ''
as $function$
  select public.submit_service_request(p_id, pg_catalog.current_setting('marketplace_test.category')::uuid,
    'PRIVATE-title kitchen pipe', 'PRIVATE-description of the original request, never a public summary.',
    'PRIVATE-city', 'PRIVATE-address apartment 123', p_preferred, p_photos, true);
$function$;

create function pg_temp.marketplace_quote_sql(p_request_id uuid, p_changes jsonb default '{}'::jsonb)
returns text language plpgsql security invoker set search_path = ''
as $function$
declare
  payload jsonb := '{"amount_minor":12500,"currency":"EGP","duration_minutes":60,"notes":"Quote terms","expected_revision":0}'::jsonb || p_changes;
begin
  return pg_catalog.format('select public.save_provider_quote(%L::uuid,%L::integer,%L::text,%L::integer,%L::text,%L::integer)',
    p_request_id, payload ->> 'amount_minor', payload ->> 'currency', payload ->> 'duration_minutes',
    payload ->> 'notes', payload ->> 'expected_revision');
end;
$function$;

do $temp_grants$
begin
  execute pg_catalog.format('grant usage on schema %I to authenticated, anon, service_role',
    (select nspname from pg_catalog.pg_namespace where oid = pg_catalog.pg_my_temp_schema()));
end;
$temp_grants$;
grant execute on function pg_temp.marketplace_assert(boolean,text), pg_temp.marketplace_expect_error(text,text,text),
  pg_temp.marketplace_login(uuid), pg_temp.marketplace_keys(jsonb,text[],text),
  pg_temp.marketplace_request(uuid,jsonb,timestamptz), pg_temp.marketplace_quote_sql(uuid,jsonb)
  to authenticated, anon, service_role;

do $security_contract$
declare
  relation_name text;
  routine_name text;
  api_role text;
begin
  perform pg_temp.marketplace_assert(current_user = 'postgres', 'whole marketplace test starts as postgres');
  foreach relation_name in array array['request_marketplace_listings','provider_quotes','service_jobs','job_status_history'] loop
    perform pg_temp.marketplace_assert((select relrowsecurity and pg_catalog.pg_get_userbyid(relowner) = 'postgres'
      from pg_catalog.pg_class where oid = ('public.' || relation_name)::regclass), 'RLS and postgres ownership: ' || relation_name);
    foreach api_role in array array['anon','authenticated','service_role'] loop
      perform pg_temp.marketplace_assert(not pg_catalog.has_table_privilege(api_role, 'public.' || relation_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        and not pg_catalog.has_any_column_privilege(api_role, 'public.' || relation_name, 'SELECT,INSERT,UPDATE,REFERENCES'),
        'no default table/column API grants: ' || api_role || '/' || relation_name);
    end loop;
  end loop;
  perform pg_temp.marketplace_assert(not exists (select 1 from pg_catalog.pg_policies where schemaname = 'public'
    and tablename in ('request_marketplace_listings','provider_quotes','service_jobs','job_status_history')),
    'RPC-only marketplace tables have no accidental permissive policies');
  perform pg_temp.marketplace_assert((select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname = 'public'
    and tablename in ('service_requests','service_request_photos')) = 2,
    'M6 retains exactly two customer-owned SELECT policies');
  perform pg_temp.marketplace_assert(not pg_catalog.has_column_privilege('authenticated','public.profiles','role','UPDATE')
    and not pg_catalog.has_schema_privilege('anon','salahly_private','USAGE'), 'profile roles and private schema remain protected');
  foreach routine_name in array array[
    'public.get_marketplace_feed(timestamptz,uuid,integer)', 'public.get_provider_request(uuid)',
    'public.get_provider_quotes(timestamptz,uuid,integer)', 'public.get_customer_quotes(uuid,timestamptz,uuid,integer)',
    'public.publish_request_listing(uuid,text,text,boolean)', 'public.save_provider_quote(uuid,integer,text,integer,text,integer)',
    'public.withdraw_provider_quote(uuid,integer)', 'public.accept_provider_quote(uuid,integer,boolean)',
    'public.get_service_jobs(timestamptz,uuid,integer)', 'public.get_service_job(uuid)',
    'public.transition_service_job(uuid,text,text)', 'public.cancel_service_request(uuid)'
  ] loop
    perform pg_temp.marketplace_assert(pg_catalog.has_function_privilege('authenticated', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', routine_name, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', routine_name, 'EXECUTE'), 'narrow RPC ACL: ' || routine_name);
  end loop;
  perform pg_temp.marketplace_assert(not exists (
    select 1 from pg_catalog.pg_proc as routine join pg_catalog.pg_namespace as namespace on namespace.oid = routine.pronamespace
    where (namespace.nspname = 'salahly_private' or (namespace.nspname = 'public' and routine.proname in (
      'get_marketplace_feed','get_provider_request','get_provider_quotes','get_customer_quotes','publish_request_listing',
      'save_provider_quote','withdraw_provider_quote','accept_provider_quote','get_service_jobs','get_service_job',
      'transition_service_job','cancel_service_request'
    ))) and (not routine.prosecdef or pg_catalog.pg_get_userbyid(routine.proowner) <> 'postgres'
      or not coalesce(routine.proconfig @> array['search_path=""'], false)
      or pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE'))
  ), 'all M7 and earlier private routines retain definer/postgres/empty-path/no-anon rules');
  foreach routine_name in array array[
    'salahly_private.marketplace_provider_eligible(uuid,uuid,text)', 'salahly_private.lock_marketplace_request(uuid)',
    'salahly_private.lock_marketplace_provider(uuid,uuid,text)', 'salahly_private.validate_marketplace_page(timestamptz,uuid,integer)',
    'salahly_private.marketplace_listing_snapshot(uuid)', 'salahly_private.provider_quote_snapshot(uuid)',
    'salahly_private.quote_opportunity_snapshot(uuid,uuid)', 'salahly_private.service_job_snapshot(uuid)',
    'salahly_private.guard_marketplace_listing()', 'salahly_private.guard_provider_quote()', 'salahly_private.guard_service_job()',
    'salahly_private.guard_job_status_history()', 'salahly_private.finish_service_job_write()',
    'salahly_private.finish_request_marketplace_status()', 'salahly_private.validate_marketplace_integrity()'
  ] loop
    perform pg_temp.marketplace_assert(not pg_catalog.has_function_privilege('authenticated',routine_name,'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role',routine_name,'EXECUTE'), 'internal-only helper: ' || routine_name);
  end loop;
  perform pg_temp.marketplace_assert(exists (select 1 from pg_catalog.pg_index where indexrelid = 'public.provider_quotes_one_accepted_idx'::regclass
    and indisunique and indisvalid and indpred is not null), 'one accepted quote per request has a valid partial unique index');
  perform pg_temp.marketplace_assert((select pg_catalog.count(*) from pg_catalog.pg_constraint
    where conrelid = 'public.service_jobs'::regclass and contype = 'f' and convalidated and not condeferrable
      and pg_catalog.cardinality(conkey) in (2,3) and confdeltype = 'r') = 2,
    'validated RESTRICT composite FKs bind request/customer and quote/request/provider');
  perform pg_temp.marketplace_assert(exists (select 1 from storage.buckets where id = 'request-photos' and not public
    and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg','image/png'])
    and (select pg_catalog.count(*) from pg_catalog.pg_policies where schemaname = 'storage' and permissive = 'RESTRICTIVE'
      and policyname like 'salahly_request_%guard' or schemaname = 'storage' and policyname = 'salahly_request_objects_client_gate') = 8,
    'M6 private bucket and eight restrictive guards preserved');
end;
$security_contract$;

do $fixtures$
declare
  fixture record;
  user_id uuid;
  category uuid := pg_catalog.gen_random_uuid();
  other_category uuid := pg_catalog.gen_random_uuid();
  path text;
  verification jsonb;
  request_id uuid;
  photo_id uuid := pg_catalog.gen_random_uuid();
  photo jsonb;
  private_request jsonb;
  key text;
begin
  perform pg_catalog.set_config('marketplace_test.category', category::text, true);
  perform pg_catalog.set_config('marketplace_test.other_category', other_category::text, true);
  insert into public.service_categories (id,slug,name_en,name_ar,description_en,description_ar,icon_key) values
    (category,'marketplace_test_' || category::text,'Original M7 EN','Original M7 AR','Fixture','Fixture','plumbing'),
    (other_category,'marketplace_test_' || other_category::text,'Other M7 EN','Other M7 AR','Fixture','Fixture','electrical');
  for fixture in select * from (values
    ('customer_a','customer','Customer A'), ('customer_b','customer','Customer B'),
    ('provider_a','provider','Provider A'), ('provider_b','provider','Provider B'),
    ('provider_other','provider','Provider Other'), ('provider_pending','provider','Provider Pending'),
    ('provider_rejected','provider','Provider Rejected'), ('provider_empty','provider','Provider Empty')
  ) as person(key,role,name) loop
    user_id := pg_catalog.gen_random_uuid();
    perform pg_catalog.set_config('marketplace_test.' || fixture.key,user_id::text,true);
    insert into auth.users (id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values (user_id,'authenticated','authenticated','marketplace-' || user_id::text || '@example.invalid',
        '{"provider":"email","providers":["email"]}'::jsonb,
        pg_catalog.jsonb_build_object('full_name',fixture.name,'role',fixture.role),pg_catalog.now(),pg_catalog.now());
    if fixture.role = 'provider' and fixture.key <> 'provider_empty' then
      perform pg_temp.marketplace_login(user_id);
      perform public.save_provider_onboarding(user_id,'Experienced provider fixture, no real credential.',
        array[case when fixture.key = 'provider_other' then other_category else category end], array['Cairo'],
        '[{"weekday":1,"start_minute":480,"end_minute":540}]'::jsonb);
      path := user_id::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','') || '.jpg';
      insert into storage.objects (bucket_id,name,owner_id,metadata) values
        ('provider-verification',path,user_id::text,'{"mimetype":"image/jpeg","size":1}'::jsonb);
      verification := public.submit_provider_verification(user_id,path,true);
      if fixture.key <> 'provider_pending' then
        perform public.review_provider_verification((verification #>> '{verification,id}')::uuid,
          case when fixture.key = 'provider_rejected' then 'rejected' else 'verified' end,
          case when fixture.key = 'provider_rejected' then 'Synthetic rejection' else null end,'rollback-reviewer');
      end if;
    end if;
  end loop;
  update public.profiles set phone = 'PRIVATE-phone', city = 'PRIVATE-profile-city'
    where id = pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
  perform pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
  foreach key in array array['main','cancel','unpublished','closed','bounds_min','bounds_max'] loop
    request_id := pg_catalog.gen_random_uuid();
    perform pg_catalog.set_config('marketplace_test.request_' || key,request_id::text,true);
    if key = 'main' then
      path := auth.uid()::text || '/' || request_id::text || '/' || photo_id::text || '.jpg';
      insert into storage.objects (bucket_id,name,owner_id,metadata)
        values ('request-photos',path,auth.uid()::text,'{"mimetype":"image/jpeg","size":1}'::jsonb);
      photo := pg_catalog.jsonb_build_object('id',photo_id,'storage_path',path,'mime_type','image/jpeg','size_bytes',1);
      private_request := pg_temp.marketplace_request(request_id,pg_catalog.jsonb_build_array(photo),pg_catalog.clock_timestamp() + interval '1 hour');
      perform pg_catalog.set_config('marketplace_test.private_request',private_request::text,true);
      perform pg_catalog.set_config('marketplace_test.photo',photo::text,true);
    else
      perform pg_temp.marketplace_request(request_id);
    end if;
  end loop;
  perform public.cancel_service_request(pg_catalog.current_setting('marketplace_test.request_closed')::uuid);
  perform pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_b')::uuid);
  request_id := pg_catalog.gen_random_uuid();
  perform pg_catalog.set_config('marketplace_test.request_foreign',request_id::text,true);
  perform pg_temp.marketplace_request(request_id);
end;
$fixtures$;

-- Deliberately broad unrelated Storage permissions must not reveal a photo.
grant select,insert,update,delete on storage.objects,storage.buckets to authenticated,anon;
create policy salahly_marketplace_test_storage_all on storage.objects for all to public using (true) with check (true);

select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
do $private_before_opt_in$
begin
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() = '{"items":[],"has_more":false,"eligible":true}'::jsonb,
    'verified provider sees no automatically published legacy requests');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_provider_request(%L)',
    pg_catalog.current_setting('marketplace_test.request_main')),'P0001','marketplace.errors.not_found');
  perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(pg_catalog.current_setting('marketplace_test.request_unpublished')::uuid),
    'P0001','marketplace.errors.unpublished');
  perform pg_temp.marketplace_assert(not exists (select 1 from public.service_requests)
    and not exists (select 1 from public.service_request_photos)
    and not exists (select 1 from storage.objects where bucket_id = 'request-photos'),
    'provider has no original request/location/photo rows despite broad Storage policy');
end;
$private_before_opt_in$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
set local role authenticated;
do $publication$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  listing jsonb;
  result jsonb;
  invalid record;
begin
  result := public.get_customer_quotes(request_id);
  perform pg_temp.marketplace_keys(result,array['request_id','customer_id','request_status','listing','quotes','has_more','job'],
    'empty customer quote book has exact wire keys');
  perform pg_temp.marketplace_assert(result -> 'listing' = 'null'::jsonb and result -> 'quotes' = '[]'::jsonb
    and result -> 'job' = 'null'::jsonb and result -> 'has_more' = 'false'::jsonb, 'unpublished quote book is side-effect free');
  perform pg_temp.marketplace_expect_error('select public.get_marketplace_feed()','42501','marketplace.errors.access');
  perform pg_temp.marketplace_expect_error('select public.get_provider_quotes()','42501','marketplace.errors.access');
  perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(request_id),'42501','marketplace.errors.access');
  for invalid in select * from (values
    (null::text,'Cairo',true,'summary'), ('123456789','Cairo',true,'summary'), (E' \t\n ','Cairo',true,'summary'),
    (pg_catalog.repeat('s',1001),'Cairo',true,'summary'), ('Public summary',null::text,true,'city'),
    ('Public summary','x',true,'city'), ('Public summary',E' \r\n ',true,'city'),
    ('Public summary',pg_catalog.repeat('c',101),true,'city'), ('Public summary','Cairo',false,'consent'),
    ('Public summary','Cairo',null::boolean,'consent')
  ) as payload(summary,city,consent,error_key) loop
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,%L,%L,%L)',
      request_id,invalid.summary,invalid.city,invalid.consent),'P0001','marketplace.errors.' || invalid.error_key);
  end loop;
  perform pg_temp.marketplace_expect_error('select public.publish_request_listing(null,''Public summary'',''Cairo'',true)',
    'P0001','marketplace.errors.not_found');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,''Public summary'',''Cairo'',true)',
    pg_catalog.current_setting('marketplace_test.request_foreign')),'P0001','marketplace.errors.not_found');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,''Public summary'',''Cairo'',true)',
    pg_catalog.current_setting('marketplace_test.request_closed')),'P0001','marketplace.errors.status');
  listing := public.publish_request_listing(request_id,E' \tPublic repair summary only\n ',E' \rCairo\t ',true);
  perform pg_temp.marketplace_keys(listing,array['request_id','category_id','category_name_en','category_name_ar','category_icon_key',
    'summary','city','published_at','request_status'],'listing has only the exact redacted wire keys');
  perform pg_temp.marketplace_assert(listing ->> 'summary' = 'Public repair summary only' and listing ->> 'city' = 'Cairo'
    and listing ->> 'category_name_en' = 'Original M7 EN' and listing ->> 'category_icon_key' = 'plumbing'
    and listing::text not like '%PRIVATE-%'
    and public.publish_request_listing(request_id,'Public repair summary only','Cairo',true) = listing,
    'explicit summary/city are trimmed, immutable and exactly retryable, never copied from private content');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,null,''Cairo'',true)',request_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,''Public repair summary only'',''cairo'',true)',request_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.publish_request_listing(%L,''Public repair summary only'',''Cairo'',false)',request_id),
    'P0001','marketplace.errors.consent');
  perform pg_catalog.set_config('marketplace_test.listing',listing::text,true);
  result := public.publish_request_listing(pg_catalog.current_setting('marketplace_test.request_bounds_min')::uuid,pg_catalog.repeat('s',10),'AA',true);
  perform pg_temp.marketplace_assert(pg_catalog.char_length(result ->> 'summary') = 10 and result ->> 'city' = 'AA','minimum listing lengths accepted');
  result := public.publish_request_listing(pg_catalog.current_setting('marketplace_test.request_bounds_max')::uuid,pg_catalog.repeat('s',1000),pg_catalog.repeat('c',100),true);
  perform pg_temp.marketplace_assert(pg_catalog.char_length(result ->> 'summary') = 1000 and pg_catalog.char_length(result ->> 'city') = 100,
    'maximum listing lengths accepted');
  perform public.publish_request_listing(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,'Public cancellation fixture','Cairo',true);
end;
$publication$;

set local role postgres;
update public.service_categories set name_en = 'Renamed catalog EN',name_ar = 'Renamed catalog AR',icon_key = 'painting'
  where id = pg_catalog.current_setting('marketplace_test.category')::uuid;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
do $eligibility_and_validation$
declare
  own_id uuid := auth.uid();
  category uuid := pg_catalog.current_setting('marketplace_test.category')::uuid;
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  result jsonb;
  invalid record;
  limit_value integer;
  relation_name text;
begin
  result := public.get_provider_request(request_id);
  perform pg_temp.marketplace_keys(result,array['listing','quote','can_quote'],'opportunity has exact wire keys');
  perform pg_temp.marketplace_assert(result -> 'listing' = pg_catalog.current_setting('marketplace_test.listing')::jsonb
    and result -> 'quote' = 'null'::jsonb and result -> 'can_quote' = 'true'::jsonb,
    'matching verified provider can quote explicit listing with original category snapshot');
  perform pg_temp.marketplace_assert(public.get_provider_quotes() = '{"items":[],"has_more":false}'::jsonb,'own quote list initially empty');
  perform pg_temp.marketplace_expect_error('select public.get_customer_quotes(null)','42501','marketplace.errors.access');
  perform pg_temp.marketplace_expect_error('select public.publish_request_listing(null,null,null,true)','42501','marketplace.errors.access');
  perform pg_temp.marketplace_expect_error('select public.accept_provider_quote(null,1,true)','42501','marketplace.errors.access');
  foreach relation_name in array array['request_marketplace_listings','provider_quotes','service_jobs','job_status_history'] loop
    perform pg_temp.marketplace_expect_error('select * from public.' || relation_name,'42501');
    perform pg_temp.marketplace_expect_error('insert into public.' || relation_name || ' default values','42501');
    perform pg_temp.marketplace_expect_error('update public.' || relation_name || ' set '
      || case when relation_name = 'request_marketplace_listings' then 'published_at = now()' else 'created_at = now()' end,'42501');
    perform pg_temp.marketplace_expect_error('delete from public.' || relation_name,'42501');
  end loop;
  perform pg_temp.marketplace_expect_error('select salahly_private.service_job_snapshot(null)','42501');
  perform pg_temp.marketplace_expect_error('select salahly_private.marketplace_provider_eligible(auth.uid())','42501');
  perform pg_temp.marketplace_expect_error('select salahly_private.validate_marketplace_integrity()','42501');
  foreach limit_value in array array[0,-1,51,null::integer] loop
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_marketplace_feed(null,null,%L)',limit_value),'P0001','marketplace.errors.invalid');
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_provider_quotes(null,null,%L)',limit_value),'P0001','marketplace.errors.invalid');
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_service_jobs(null,null,%L)',limit_value),'P0001','marketplace.errors.invalid');
  end loop;
  perform pg_temp.marketplace_expect_error('select public.get_marketplace_feed(now(),null,20)','P0001','marketplace.errors.invalid');
  perform pg_temp.marketplace_expect_error('select public.get_provider_quotes(null,gen_random_uuid(),20)','P0001','marketplace.errors.invalid');
  perform pg_temp.marketplace_expect_error('select public.get_service_jobs(''infinity'',gen_random_uuid(),20)','P0001','marketplace.errors.invalid');
  perform public.save_provider_onboarding(own_id,'',array[category],array['Cairo district'],'[]'::jsonb);
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() -> 'eligible' = 'true'::jsonb
    and public.get_marketplace_feed() -> 'items' = '[]'::jsonb, 'basic eligibility is not a claim of distance/substring matching');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_provider_request(%L)',request_id),'P0001','marketplace.errors.not_found');
  perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(request_id),'P0001','marketplace.errors.ineligible');
  perform public.save_provider_onboarding(own_id,'',array[category],'{}'::text[],'[]'::jsonb);
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() -> 'eligible' = 'false'::jsonb,'verified without area is not feed-eligible');
  perform public.save_provider_onboarding(own_id,'','{}'::uuid[],array['Cairo'],'[]'::jsonb);
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() -> 'eligible' = 'false'::jsonb,'verified without active skill is not feed-eligible');
  perform public.save_provider_onboarding(own_id,'',array[category],array[E' \tcAiRo\n '],'[]'::jsonb);
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() -> 'eligible' = 'true'::jsonb
    and public.get_provider_request(request_id) -> 'can_quote' = 'true'::jsonb,
    'exact trimmed case-insensitive area label matches; weekly availability is not an eligibility promise');
  for invalid in select * from (values
    ('{"amount_minor":null}'::jsonb,'amount'), ('{"amount_minor":0}'::jsonb,'amount'),
    ('{"amount_minor":100000001}'::jsonb,'amount'), ('{"currency":null}'::jsonb,'currency'),
    ('{"currency":"egp"}'::jsonb,'currency'), ('{"currency":"USD"}'::jsonb,'currency'),
    ('{"currency":" EGP "}'::jsonb,'currency'), ('{"duration_minutes":null}'::jsonb,'duration'),
    ('{"duration_minutes":0}'::jsonb,'duration'), ('{"duration_minutes":43201}'::jsonb,'duration'),
    ('{"notes":null}'::jsonb,'notes'), (pg_catalog.jsonb_build_object('notes',pg_catalog.repeat('n',1001)),'notes'),
    ('{"expected_revision":null}'::jsonb,'invalid'), ('{"expected_revision":-1}'::jsonb,'invalid'),
    ('{"expected_revision":1}'::jsonb,'conflict')
  ) as payload(changes,error_key) loop
    perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(request_id,invalid.changes),'P0001','marketplace.errors.' || invalid.error_key);
  end loop;
  perform pg_temp.marketplace_assert(public.get_provider_request(request_id) -> 'quote' = 'null'::jsonb,
    'validation failures never create a partial quote');
end;
$eligibility_and_validation$;

set local role postgres;
do $ineligible_roles$
declare
  key text;
  result jsonb;
begin
  foreach key in array array['provider_empty','provider_pending','provider_rejected','provider_other'] loop
    perform pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.' || key)::uuid);
    set local role authenticated;
    result := public.get_marketplace_feed();
    perform pg_temp.marketplace_assert(result -> 'items' = '[]'::jsonb
      and result ->> 'eligible' = case when key = 'provider_other' then 'true' else 'false' end,
      'feed rejects absent/pending/rejected credentials or a different active skill: ' || key);
    perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(pg_catalog.current_setting('marketplace_test.request_main')::uuid),
      'P0001','marketplace.errors.ineligible');
    set local role postgres;
  end loop;
end;
$ineligible_roles$;

select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
do $quote_revisions$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  quote jsonb;
  retry jsonb;
  bounds jsonb;
begin
  quote := public.save_provider_quote(request_id,12500,'EGP',60,E' \tQuote terms\n ',0);
  perform pg_temp.marketplace_keys(quote,array['id','request_id','provider_id','provider_name','amount_minor','currency',
    'duration_minutes','notes','revision','status','created_at','updated_at'],'quote has only exact comparison wire keys');
  perform pg_temp.marketplace_assert(quote ->> 'revision' = '1' and quote ->> 'status' = 'pending'
    and quote ->> 'provider_name' = 'Provider A' and quote ->> 'notes' = 'Quote terms'
    and quote -> 'created_at' = quote -> 'updated_at'
    and public.save_provider_quote(request_id,12500,'EGP',60,'Quote terms',0) = quote,
    'new quote starts at revision1 with normalized notes and exact canonical retry');
  retry := public.save_provider_quote(request_id,12500,'EGP',60,'Quote terms',1);
  perform pg_temp.marketplace_assert(retry ->> 'revision' = '2' and retry -> 'id' = quote -> 'id'
    and retry -> 'created_at' = quote -> 'created_at' and (retry ->> 'updated_at')::timestamptz > (quote ->> 'updated_at')::timestamptz,
    'explicit same-terms save increments revision, never creates another provider quote');
  quote := public.save_provider_quote(request_id,13500,'EGP',90,'Updated quote',2);
  perform pg_temp.marketplace_assert(quote ->> 'revision' = '3' and quote ->> 'amount_minor' = '13500'
    and public.save_provider_quote(request_id,13500,'EGP',90,'Updated quote',2) = quote,
    'changed-price save/retry use exact expected revision and terms');
  perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(request_id,'{"expected_revision":1}'::jsonb),'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,2)',quote ->> 'id'),'P0001','marketplace.errors.conflict');
  retry := public.withdraw_provider_quote((quote ->> 'id')::uuid,3);
  perform pg_temp.marketplace_assert(retry ->> 'status' = 'withdrawn' and retry ->> 'revision' = '3'
    and public.withdraw_provider_quote((quote ->> 'id')::uuid,3) = retry
    and public.save_provider_quote(request_id,13500,'EGP',90,'Updated quote',2) = retry,
    'withdrawal retains revision; withdrawal and late save retries never reactivate it');
  quote := public.save_provider_quote(request_id,13500,'EGP',90,'Updated quote',3);
  perform pg_temp.marketplace_assert(quote ->> 'status' = 'pending' and quote ->> 'revision' = '4','explicit expected-current save reactivates withdrawn quote');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,3)',quote ->> 'id'),'P0001','marketplace.errors.conflict');
  update public.profiles set full_name = 'Renamed Provider A' where id = auth.uid();
  quote := public.save_provider_quote(request_id,12500,'EGP',60,'Quote terms',4);
  perform pg_temp.marketplace_assert(quote ->> 'revision' = '5' and quote ->> 'provider_name' = 'Provider A',
    'first-quote name snapshot survives live name changes and terms returning to an earlier value');
  perform pg_catalog.set_config('marketplace_test.quote_a',quote::text,true);
  bounds := public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,1,'EGP',1,E' \t\n ',0);
  perform pg_temp.marketplace_assert(bounds ->> 'notes' = '' and bounds ->> 'amount_minor' = '1' and bounds ->> 'duration_minutes' = '1',
    'minimum integer amount/duration and empty notes accepted');
  bounds := public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,100000000,'EGP',43200,pg_catalog.repeat('n',1000),1);
  perform pg_temp.marketplace_assert(bounds ->> 'amount_minor' = '100000000' and bounds ->> 'duration_minutes' = '43200'
    and pg_catalog.char_length(bounds ->> 'notes') = 1000,'inclusive upper integer/note bounds accepted');
  bounds := public.withdraw_provider_quote((bounds ->> 'id')::uuid,2);
  perform pg_catalog.set_config('marketplace_test.withdrawn',bounds::text,true);
end;
$quote_revisions$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_b')::uuid);
set local role authenticated;
do $competition$
declare
  result jsonb;
begin
  result := public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_main')::uuid,15000,'EGP',45,'Competitor quote',0);
  perform pg_catalog.set_config('marketplace_test.quote_b',result::text,true);
  result := public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,17000,'EGP',120,'Pending cancellation',0);
  perform pg_catalog.set_config('marketplace_test.cancel_quote',result::text,true);
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,5)',
    pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id'),'P0001','marketplace.errors.not_found');
end;
$competition$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_b')::uuid);
set local role authenticated;
do $foreign_customer$
begin
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_customer_quotes(%L)',
    pg_catalog.current_setting('marketplace_test.request_main')),'P0001','marketplace.errors.not_found');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,5,true)',
    pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id'),'P0001','marketplace.errors.not_found');
end;
$foreign_customer$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
set local role authenticated;
do $compare_and_cancel$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  quote_a uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  page jsonb;
  next_page jsonb;
  cancelled jsonb;
  limit_value integer;
begin
  page := public.get_customer_quotes(request_id,null,null,1);
  next_page := public.get_customer_quotes(request_id,(page #>> '{quotes,0,created_at}')::timestamptz,(page #>> '{quotes,0,id}')::uuid,1);
  perform pg_temp.marketplace_assert(page -> 'has_more' = 'true'::jsonb and next_page -> 'has_more' = 'false'::jsonb
    and page #>> '{quotes,0,id}' = pg_catalog.current_setting('marketplace_test.quote_b')::jsonb ->> 'id'
    and next_page #>> '{quotes,0,id}' = quote_a::text and page ->> 'request_status' = 'open'
    and page -> 'job' = 'null'::jsonb and page::text not like '%PRIVATE-%',
    'quote comparison is keyset-paginated, owner-only, and contains no credential/contact/private request fields');
  foreach limit_value in array array[0,51,null::integer] loop
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_customer_quotes(%L,null,null,%L)',request_id,limit_value),
      'P0001','marketplace.errors.invalid');
  end loop;
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_customer_quotes(%L,now(),null,20)',request_id),'P0001','marketplace.errors.invalid');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,5,false)',quote_a),'P0001','marketplace.errors.consent');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,5,null)',quote_a),'P0001','marketplace.errors.consent');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,4,true)',quote_a),'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,2,true)',quote_a),'P0001','marketplace.errors.conflict');
  cancelled := public.cancel_service_request(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid);
  perform pg_temp.marketplace_assert(cancelled = public.cancel_service_request(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid)
    and cancelled ->> 'status' = 'cancelled','M6 repeated cancellation keeps exact canonical timestamp/content');
  page := public.get_customer_quotes(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid);
  perform pg_temp.marketplace_assert(page ->> 'request_status' = 'cancelled' and page -> 'job' = 'null'::jsonb
    and exists (select 1 from pg_catalog.jsonb_array_elements(page -> 'quotes') as item(value) where value ->> 'status' = 'cancelled')
    and exists (select 1 from pg_catalog.jsonb_array_elements(page -> 'quotes') as item(value) where value ->> 'status' = 'withdrawn'),
    'cancellation atomically closes pending quotes but retains already-withdrawn history');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,1,true)',
    pg_catalog.current_setting('marketplace_test.cancel_quote')::jsonb ->> 'id'),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_assert(public.publish_request_listing(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,
    'Public cancellation fixture','Cairo',true) ->> 'request_status' = 'cancelled','same listing retry returns canonical closed state');
end;
$compare_and_cancel$;

set local role postgres;
do $eligibility_at_acceptance$
declare
  provider uuid := pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
  customer uuid := pg_catalog.current_setting('marketplace_test.customer_a')::uuid;
  category uuid := pg_catalog.current_setting('marketplace_test.category')::uuid;
  quote_id uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  action integer;
begin
  for action in 1..5 loop
    if action = 1 then update public.service_categories set is_active = false where id = category;
    elsif action = 2 then update public.profiles set role = 'customer' where id = provider;
    elsif action = 3 then update public.provider_verifications set status = 'rejected',review_note = 'Synthetic revocation' where user_id = provider;
    else
      perform pg_temp.marketplace_login(provider);
      perform public.save_provider_onboarding(provider,'',case when action = 4 then '{}'::uuid[] else array[category] end,
        case when action = 5 then array['Another area'] else array['Cairo'] end,'[]'::jsonb);
    end if;
    perform pg_temp.marketplace_login(customer);
    set local role authenticated;
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,5,true)',quote_id),
      'P0001','marketplace.errors.ineligible');
    perform pg_temp.marketplace_assert(public.get_customer_quotes(pg_catalog.current_setting('marketplace_test.request_main')::uuid) -> 'job' = 'null'::jsonb,
      'failed mutable eligibility recheck creates no job/assignment/history');
    set local role postgres;
    update public.service_categories set is_active = true where id = category;
    update public.profiles set role = 'provider' where id = provider;
    update public.provider_verifications set status = 'verified',review_note = null where user_id = provider;
    perform pg_temp.marketplace_login(provider);
    perform public.save_provider_onboarding(provider,'',array[category],array['Cairo'],'[]'::jsonb);
  end loop;
end;
$eligibility_at_acceptance$;

select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
set local role authenticated;
do $acceptance$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  quote_id uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  job jsonb;
  book jsonb;
  original jsonb := pg_catalog.current_setting('marketplace_test.private_request')::jsonb;
  retried_request jsonb;
begin
  job := public.accept_provider_quote(quote_id,5,true);
  perform pg_temp.marketplace_keys(job,array['id','request_id','quote_id','customer_id','provider_id','provider_name','amount_minor','currency',
    'duration_minutes','notes','quote_revision','status','created_at','updated_at','request_title','request_description','city','address','preferred_at','history'],
    'job has exact consented wire keys, no photos, contacts, or credentials');
  perform pg_temp.marketplace_keys(job #> '{history,0}',array['id','from_status','status','actor_id','created_at'],'history has exact wire keys');
  perform pg_temp.marketplace_assert(job ->> 'status' = 'selected' and job ->> 'provider_name' = 'Provider A'
    and job ->> 'amount_minor' = '12500' and job ->> 'currency' = 'EGP' and job ->> 'duration_minutes' = '60' and job ->> 'quote_revision' = '5'
    and job ->> 'notes' = 'Quote terms' and job ->> 'request_title' = original ->> 'title'
    and job ->> 'request_description' = original ->> 'description' and job -> 'city' = original -> 'city'
    and job -> 'address' = original -> 'address' and job -> 'preferred_at' = original -> 'preferred_at'
    and pg_catalog.jsonb_array_length(job -> 'history') = 1 and job #> '{history,0,from_status}' = 'null'::jsonb
    and job #>> '{history,0,actor_id}' = auth.uid()::text and job #> '{history,0,created_at}' = job -> 'created_at'
    and job -> 'created_at' = job -> 'updated_at', 'selection freezes quote/name, discloses only consented original details, and creates initial customer event');
  perform pg_temp.marketplace_assert(public.accept_provider_quote(quote_id,5,true) = job and public.get_service_job((job ->> 'id')::uuid) = job,
    'exact acceptance retry/get return one canonical job without duplicate event');
  book := public.get_customer_quotes(request_id);
  perform pg_temp.marketplace_assert(book ->> 'request_status' = 'assigned' and book -> 'job' = job
    and (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(book -> 'quotes') as quote(value) where value ->> 'status' = 'accepted') = 1
    and (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(book -> 'quotes') as quote(value) where value ->> 'status' = 'not_selected') = 1,
    'one acceptance closes pending competitor and atomically assigns request');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,1,true)',
    pg_catalog.current_setting('marketplace_test.quote_b')::jsonb ->> 'id'),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.accept_provider_quote(%L,4,true)',quote_id),'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.cancel_service_request(%L)',request_id),'P0001','requests.errors.status');
  perform pg_temp.marketplace_assert(public.publish_request_listing(request_id,'Public repair summary only','Cairo',true) ->> 'request_status' = 'assigned',
    'publication retry on assignment returns canonical assigned listing');
  retried_request := public.submit_service_request(request_id,(original ->> 'category_id')::uuid,original ->> 'title',original ->> 'description',
    original ->> 'city',original ->> 'address',(original ->> 'preferred_at')::timestamptz,
    pg_catalog.jsonb_build_array(pg_catalog.current_setting('marketplace_test.photo')::jsonb),true);
  perform pg_temp.marketplace_assert(retried_request ->> 'status' = 'assigned' and retried_request -> 'cancelled_at' = 'null'::jsonb
    and (retried_request - 'status') = (original - 'status'), 'M6 exact submission retry preserves assigned state and immutable content/photos');
  perform pg_catalog.set_config('marketplace_test.job',job::text,true);
end;
$acceptance$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
do $assigned_provider_privacy$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  quote_id uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  job_id uuid := (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
  result jsonb;
begin
  result := public.get_provider_request(request_id);
  perform pg_temp.marketplace_assert(result #>> '{quote,status}' = 'accepted' and result -> 'can_quote' = 'false'::jsonb
    and result::text not like '%PRIVATE-%','historical quote opportunity still contains only opt-in listing and own quote');
  perform pg_temp.marketplace_assert(public.save_provider_quote(request_id,12500,'EGP',60,'Quote terms',4) = result -> 'quote',
    'late exact save retry after acceptance returns accepted quote without reopening');
  perform pg_temp.marketplace_expect_error(pg_temp.marketplace_quote_sql(request_id,'{"expected_revision":5}'::jsonb),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,5)',quote_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_service_request(%L)',request_id),'42501','requests.errors.access');
  perform pg_temp.marketplace_assert(not exists (select 1 from public.service_requests) and not exists (select 1 from public.service_request_photos)
    and not exists (select 1 from storage.objects where bucket_id = 'request-photos')
    and public.get_service_job(job_id) ->> 'address' = 'PRIVATE-address apartment 123',
    'selected provider gets consented detail ONLY through participant job RPC, never base requests/photos/Storage');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''selected'',''completed'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''selected'',''awaiting_confirmation'')',job_id),'P0001','marketplace.errors.status');
  result := public.transition_service_job(job_id,'selected','on_the_way');
  perform pg_temp.marketplace_assert(result ->> 'status' = 'on_the_way' and pg_catalog.jsonb_array_length(result -> 'history') = 2
    and result #>> '{history,1,actor_id}' = auth.uid()::text and result #> '{history,1,created_at}' = result -> 'updated_at',
    'provider may advance selected to on_the_way with same timestamp on job and actor event');
  perform public.save_provider_onboarding(auth.uid(),'','{}'::uuid[],'{}'::text[],'[]'::jsonb);
  perform pg_temp.marketplace_assert(public.get_marketplace_feed() -> 'eligible' = 'false'::jsonb
    and public.get_provider_request(request_id) -> 'can_quote' = 'false'::jsonb
    and public.get_provider_request(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid) #>> '{quote,status}' = 'withdrawn',
    'loss of eligibility hides feed but preserves own historical quote listings');
  perform pg_temp.marketplace_assert(public.withdraw_provider_quote((pg_catalog.current_setting('marketplace_test.withdrawn')::jsonb ->> 'id')::uuid,2)
    = pg_catalog.current_setting('marketplace_test.withdrawn')::jsonb,'closed/ineligible identical withdrawal retry is canonical');
end;
$assigned_provider_privacy$;

set local role postgres;
update public.profiles set role = 'customer' where id = pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
update public.provider_verifications set status = 'rejected',review_note = 'Synthetic later revocation'
  where user_id = pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
update public.service_categories set is_active = false where id = pg_catalog.current_setting('marketplace_test.category')::uuid;
set local role authenticated;
do $immutable_participant_lifecycle$
declare
  job_id uuid := (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
  result jsonb;
begin
  perform pg_temp.marketplace_assert(public.get_service_job(job_id) ->> 'status' = 'on_the_way',
    'job access survives participant profile-role, credential, skill, area, and catalog changes');
  result := public.transition_service_job(job_id,'on_the_way','in_progress');
  perform pg_temp.marketplace_assert(result ->> 'status' = 'in_progress' and pg_catalog.jsonb_array_length(result -> 'history') = 3
    and public.transition_service_job(job_id,'selected','on_the_way') = result,
    'immutable selected-provider ID governs progress and historical edge retry even after global role change');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''in_progress'',''cancelled'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''selected'',''in_progress'')',job_id),'P0001','marketplace.errors.conflict');
  result := public.transition_service_job(job_id,'in_progress','awaiting_confirmation');
  perform pg_temp.marketplace_assert(result ->> 'status' = 'awaiting_confirmation' and pg_catalog.jsonb_array_length(result -> 'history') = 4,
    'provider requests completion without completing on behalf of customer');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''awaiting_confirmation'',''completed'')',job_id),'P0001','marketplace.errors.status');
end;
$immutable_participant_lifecycle$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
set local role authenticated;
do $customer_completion$
declare
  job_id uuid := (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
  quote_id uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  result jsonb;
begin
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''selected'',''on_the_way'')',job_id),'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''awaiting_confirmation'',''cancelled'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''awaiting_confirmation'',''in_progress'')',job_id),'P0001','marketplace.errors.status');
  result := public.transition_service_job(job_id,'awaiting_confirmation','completed');
  perform pg_temp.marketplace_assert(result ->> 'status' = 'completed' and pg_catalog.jsonb_array_length(result -> 'history') = 5
    and result #>> '{history,4,actor_id}' = auth.uid()::text and result #> '{history,4,created_at}' = result -> 'updated_at'
    and public.transition_service_job(job_id,'awaiting_confirmation','completed') = result,
    'only original customer completes; exact confirmation retry creates no sixth event');
  perform pg_temp.marketplace_assert(public.accept_provider_quote(quote_id,5,true) = result,
    'acceptance retry returns progressed canonical job despite provider/categorization eligibility loss');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''completed'',''selected'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''completed'',''cancelled'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,null,''completed'')',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''completed'',''booked'')',job_id),'P0001','marketplace.errors.status');
  perform pg_catalog.set_config('marketplace_test.completed_job',result::text,true);
end;
$customer_completion$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
select pg_temp.marketplace_assert(public.transition_service_job(
  (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid,'on_the_way','in_progress')
    = pg_catalog.current_setting('marketplace_test.completed_job')::jsonb,
  'late provider edge retry returns completed canonical job, never rewinds history');

set local role postgres;
update public.profiles set role = 'provider' where id = pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
update public.provider_verifications set status = 'verified',review_note = null where user_id = pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
update public.service_categories set is_active = true where id = pg_catalog.current_setting('marketplace_test.category')::uuid;
select public.save_provider_onboarding(auth.uid(),'',array[pg_catalog.current_setting('marketplace_test.category')::uuid],array['Cairo'],'[]'::jsonb);

do $job_cancel_branches$
declare
  customer uuid := pg_catalog.current_setting('marketplace_test.customer_a')::uuid;
  provider uuid := pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
  request_id uuid;
  quote jsonb;
  job jsonb;
  branch integer;
begin
  for branch in 1..4 loop
    perform pg_temp.marketplace_login(customer);
    request_id := pg_catalog.gen_random_uuid();
    set local role authenticated;
    perform pg_temp.marketplace_request(request_id);
    perform public.publish_request_listing(request_id,'Public pre-work cancellation','Cairo',true);
    set local role postgres;
    perform pg_temp.marketplace_login(provider);
    set local role authenticated;
    quote := public.save_provider_quote(request_id,10000,'EGP',30,'',0);
    set local role postgres;
    perform pg_temp.marketplace_login(customer);
    set local role authenticated;
    job := public.accept_provider_quote((quote ->> 'id')::uuid,1,true);
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''selected'',''in_progress'')',job ->> 'id'),
      'P0001','marketplace.errors.status');
    set local role postgres;
    if branch > 2 then
      perform pg_temp.marketplace_login(provider);
      set local role authenticated;
      job := public.transition_service_job((job ->> 'id')::uuid,'selected','on_the_way');
      set local role postgres;
    end if;
    perform pg_temp.marketplace_login(case when branch in (1,3) then customer else provider end);
    set local role authenticated;
    job := public.transition_service_job((job ->> 'id')::uuid,job ->> 'status','cancelled');
    perform pg_temp.marketplace_assert(job ->> 'status' = 'cancelled'
      and public.transition_service_job((job ->> 'id')::uuid,case when branch <= 2 then 'selected' else 'on_the_way' end,'cancelled') = job,
      'either participant cancels only pre-work with canonical retry: branch ' || branch);
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''cancelled'',''in_progress'')',job ->> 'id'),
      'P0001','marketplace.errors.status');
    set local role postgres;
    perform pg_temp.marketplace_login(customer);
    set local role authenticated;
    perform pg_temp.marketplace_assert(public.get_customer_quotes(request_id) ->> 'request_status' = 'assigned'
      and public.accept_provider_quote((quote ->> 'id')::uuid,1,true) = job,
      'job cancellation leaves original request assigned and selected quote frozen');
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.cancel_service_request(%L)',request_id),'P0001','requests.errors.status');
    set local role postgres;
  end loop;
end;
$job_cancel_branches$;

do $trusted_integrity$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.request_main')::uuid;
  quote_id uuid := (pg_catalog.current_setting('marketplace_test.quote_a')::jsonb ->> 'id')::uuid;
  job_id uuid := (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
  statement_text text;
  job jsonb;
begin
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.request_marketplace_listings set summary = ''Changed public summary'' where request_id = %L',request_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.request_marketplace_listings set city = ''Changed city'',consented_at = now(),published_at = now() where request_id = %L',request_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('delete from public.request_marketplace_listings where request_id = %L',request_id),'P0001','marketplace.errors.status');
  foreach statement_text in array array[
    'amount_minor = amount_minor + 1', 'currency = ''USD''', 'duration_minutes = 120', 'notes = ''Repriced''',
    'revision = revision + 1', 'provider_name = ''Impersonated provider''', 'provider_id = gen_random_uuid()',
    'request_id = gen_random_uuid()', 'created_at = now()'
  ] loop
    perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.provider_quotes set %s where id = %L',statement_text,quote_id),
      'P0001','marketplace.errors.conflict');
  end loop;
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.provider_quotes set status = ''withdrawn'',updated_at = updated_at + interval ''1 second'' where id = %L',quote_id),
    'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('delete from public.provider_quotes where id = %L',quote_id),'P0001','marketplace.errors.status');
  foreach statement_text in array array[
    'amount_minor = amount_minor + 1', 'currency = ''USD''', 'duration_minutes = 120', 'notes = ''Repriced''',
    'quote_revision = quote_revision + 1', 'provider_name = ''Impersonated provider''', 'provider_id = gen_random_uuid()',
    'customer_id = gen_random_uuid()', 'request_id = gen_random_uuid()', 'quote_id = gen_random_uuid()',
    'created_at = now()', 'disclosure_consented_at = now()'
  ] loop
    perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.service_jobs set %s where id = %L',statement_text,job_id),
      'P0001','marketplace.errors.conflict');
  end loop;
  perform pg_temp.marketplace_expect_error(pg_catalog.format('delete from public.service_jobs where id = %L',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.job_status_history set actor_id = gen_random_uuid() where job_id = %L',job_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.job_status_history set created_at = now() where job_id = %L',job_id),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('delete from public.job_status_history where job_id = %L',job_id),'P0001','marketplace.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format(
    'insert into public.job_status_history(job_id,from_status,status,actor_id,created_at) values (%L,''awaiting_confirmation'',''completed'',%L,now())',
    job_id,pg_catalog.current_setting('marketplace_test.customer_b')),'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.service_requests set title = ''Forged title'' where id = %L',request_id),
    'P0001','requests.errors.conflict');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.service_requests set status = ''open'' where id = %L',request_id),
    'P0001','requests.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.service_requests set status = ''booked'' where id = %L',request_id),
    'P0001','requests.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('update public.service_requests set status = ''assigned'' where id = %L',
    pg_catalog.current_setting('marketplace_test.request_unpublished')),'P0001','requests.errors.status');
  perform pg_temp.marketplace_expect_error(pg_catalog.format('delete from public.profiles where id = %L',
    pg_catalog.current_setting('marketplace_test.provider_a')),'23001,23503');
  select pg_catalog.to_jsonb(existing) into job from public.service_jobs as existing where id = job_id;
  perform pg_catalog.set_config('marketplace_test.job_row',job::text,true);
  perform pg_temp.marketplace_expect_error(pg_catalog.format(
    'insert into public.service_jobs select * from pg_catalog.jsonb_populate_record(null::public.service_jobs,%L::jsonb)',
    job || pg_catalog.jsonb_build_object('id',pg_catalog.gen_random_uuid(),'provider_id',pg_catalog.current_setting('marketplace_test.provider_b'))),
    'P0001','marketplace.errors.conflict');
  perform pg_temp.marketplace_assert(salahly_private.service_job_snapshot(job_id) = pg_catalog.current_setting('marketplace_test.completed_job')::jsonb,
    'all trusted tampering attempts leave accepted terms, participants, private detail, consent, and immutable history untouched');
end;
$trusted_integrity$;

-- Independently exercise uniqueness/FKs, not only friendly RPC/trigger checks.
-- These rollback-only DDL table locks exclude other sessions during the bypass.
alter table public.provider_quotes disable trigger salahly_provider_quote_guard;
select pg_temp.marketplace_expect_error(pg_catalog.format('update public.provider_quotes set status = ''accepted'' where id = %L',
  pg_catalog.current_setting('marketplace_test.quote_b')::jsonb ->> 'id'),'23505');
alter table public.provider_quotes enable trigger salahly_provider_quote_guard;
alter table public.job_status_history disable trigger salahly_job_status_history_guard;
select pg_temp.marketplace_expect_error(pg_catalog.format(
  'insert into public.job_status_history(job_id,from_status,status,actor_id,created_at) select job_id,from_status,status,actor_id,created_at from public.job_status_history where job_id = %L and status = ''selected''',
  pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id'),'23505');
alter table public.job_status_history enable trigger salahly_job_status_history_guard;
alter table public.service_jobs disable trigger salahly_service_job_guard;
alter table public.service_jobs disable trigger salahly_service_job_write;
select pg_temp.marketplace_expect_error(pg_catalog.format(
  'insert into public.service_jobs select * from pg_catalog.jsonb_populate_record(null::public.service_jobs,%L::jsonb)',
  pg_catalog.current_setting('marketplace_test.job_row')::jsonb || pg_catalog.jsonb_build_object('id',pg_catalog.gen_random_uuid())),'23505');
select pg_temp.marketplace_expect_error(pg_catalog.format(
  'insert into public.service_jobs select * from pg_catalog.jsonb_populate_record(null::public.service_jobs,%L::jsonb)',
  pg_catalog.current_setting('marketplace_test.job_row')::jsonb || pg_catalog.jsonb_build_object('id',pg_catalog.gen_random_uuid(),
    'request_id',pg_catalog.current_setting('marketplace_test.request_cancel'),
    'quote_id',pg_catalog.current_setting('marketplace_test.cancel_quote')::jsonb ->> 'id')),'23503');
select pg_temp.marketplace_expect_error(pg_catalog.format(
  'insert into public.service_jobs select * from pg_catalog.jsonb_populate_record(null::public.service_jobs,%L::jsonb)',
  pg_catalog.current_setting('marketplace_test.job_row')::jsonb || pg_catalog.jsonb_build_object('id',pg_catalog.gen_random_uuid(),
    'request_id',pg_catalog.current_setting('marketplace_test.request_cancel'),
    'quote_id',pg_catalog.current_setting('marketplace_test.cancel_quote')::jsonb ->> 'id',
    'provider_id',pg_catalog.current_setting('marketplace_test.provider_b'),
    'customer_id',pg_catalog.current_setting('marketplace_test.customer_b'))),'23503');
alter table public.service_jobs enable trigger salahly_service_job_guard;
alter table public.service_jobs enable trigger salahly_service_job_write;

do $foreign_job_isolation$
declare
  key text;
  job_id uuid := (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
  result jsonb;
begin
  foreach key in array array['customer_b','provider_b','provider_other'] loop
    perform pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.' || key)::uuid);
    set local role authenticated;
    perform pg_temp.marketplace_assert(public.get_service_jobs() = '{"items":[],"has_more":false}'::jsonb,
      'nonparticipant sees no jobs: ' || key);
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_service_job(%L)',job_id),'P0001','marketplace.errors.not_found');
    perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.transition_service_job(%L,''completed'',''selected'')',job_id),
      'P0001','marketplace.errors.not_found');
    if key = 'provider_b' then
      result := public.get_provider_request(pg_catalog.current_setting('marketplace_test.request_main')::uuid);
      perform pg_temp.marketplace_assert(result #>> '{quote,status}' = 'not_selected' and result -> 'can_quote' = 'false'::jsonb
        and result::text not like '%PRIVATE-%','unselected provider sees their quote/listing, never the selected job or original details');
      perform pg_temp.marketplace_assert(public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_main')::uuid,
        15000,'EGP',45,'Competitor quote',0) = result -> 'quote','not-selected exact save retry returns terminal quote without revival');
      perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,1)',result #>> '{quote,id}'),
        'P0001','marketplace.errors.status');
      result := public.get_provider_request(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid);
      perform pg_temp.marketplace_assert(public.save_provider_quote(pg_catalog.current_setting('marketplace_test.request_cancel')::uuid,
        17000,'EGP',120,'Pending cancellation',0) = result -> 'quote' and result #>> '{quote,status}' = 'cancelled',
        'cancelled exact save retry is canonical');
      perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.withdraw_provider_quote(%L,1)',result #>> '{quote,id}'),
        'P0001','marketplace.errors.status');
    elsif key = 'provider_other' then
      perform pg_temp.marketplace_expect_error(pg_catalog.format('select public.get_provider_request(%L)',
        pg_catalog.current_setting('marketplace_test.request_main')),'P0001','marketplace.errors.not_found');
    end if;
    set local role postgres;
  end loop;
end;
$foreign_job_isolation$;

-- RLS is an independent deny-all backstop even if table SELECT is granted.
grant select on public.request_marketplace_listings,public.provider_quotes,public.service_jobs,public.job_status_history to authenticated,anon;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.provider_a')::uuid);
set local role authenticated;
select pg_temp.marketplace_assert(not exists (select 1 from public.request_marketplace_listings)
  and not exists (select 1 from public.provider_quotes) and not exists (select 1 from public.service_jobs)
  and not exists (select 1 from public.job_status_history),'deny-all RLS blocks even owned M7 base rows under deliberate SELECT ACL drift');
set local role postgres;
select pg_temp.marketplace_login(null);
set local role anon;
select pg_temp.marketplace_assert(not exists (select 1 from public.request_marketplace_listings)
  and not exists (select 1 from public.provider_quotes) and not exists (select 1 from public.service_jobs)
  and not exists (select 1 from public.job_status_history),'anonymous RLS still denies all under deliberate SELECT ACL drift');
select pg_temp.marketplace_expect_error('select public.get_marketplace_feed()','42501');
select pg_temp.marketplace_expect_error('select public.get_service_job(null)','42501');
select pg_temp.marketplace_expect_error('select public.save_provider_quote(null,1,''EGP'',1,'''',0)','42501');
set local role postgres;
revoke select on public.request_marketplace_listings,public.provider_quotes,public.service_jobs,public.job_status_history from authenticated,anon;
set local role service_role;
select pg_temp.marketplace_expect_error('select * from public.service_jobs','42501');
select pg_temp.marketplace_expect_error('select public.accept_provider_quote(null,1,true)','42501');
select pg_temp.marketplace_expect_error('select public.transition_service_job(null,''selected'',''in_progress'')','42501');
set local role postgres;
set local role authenticated;
select pg_temp.marketplace_expect_error('select public.get_marketplace_feed()','42501','marketplace.errors.access');
select pg_temp.marketplace_expect_error('select public.get_service_jobs()','42501','marketplace.errors.access');
select pg_temp.marketplace_expect_error('select public.get_service_job(null)','42501','marketplace.errors.access');
select pg_temp.marketplace_expect_error('select public.get_customer_quotes(null)','42501','marketplace.errors.access');
set local role postgres;

-- Controlled equal timestamps prove the UUID half of keyset cursors. Trusted
-- synthetic INSERTs, not edits of immutable production/history records, create
-- these pagination fixtures. Their future clock is only a deterministic sort key.
create temporary table marketplace_page_fixtures (request_id uuid,quote_id uuid,job_id uuid) on commit drop;
grant select on pg_temp.marketplace_page_fixtures to authenticated;
do $pagination_fixtures$
declare
  customer uuid := pg_catalog.current_setting('marketplace_test.customer_a')::uuid;
  provider uuid := pg_catalog.current_setting('marketplace_test.provider_a')::uuid;
  stamped timestamptz := pg_catalog.clock_timestamp() + interval '1 day';
  original jsonb := pg_catalog.current_setting('marketplace_test.private_request')::jsonb;
  request_id uuid;
  quote_id uuid;
  index_number integer;
begin
  perform pg_catalog.set_config('marketplace_test.page_time',stamped::text,true);
  for index_number in 1..52 loop
    perform pg_temp.marketplace_login(customer);
    request_id := pg_catalog.gen_random_uuid();
    insert into public.service_requests select * from pg_catalog.jsonb_populate_record(null::public.service_requests,
      original || pg_catalog.jsonb_build_object('id',request_id,'status','open','cancelled_at',null,
        'created_at',stamped,'consented_at',stamped,'preferred_at',null));
    insert into public.request_marketplace_listings (request_id,summary,city,consented_at,published_at)
      values (request_id,'Public pagination summary','Cairo',stamped,stamped);
    perform pg_temp.marketplace_login(provider);
    insert into public.provider_quotes (request_id,provider_id,provider_name,amount_minor,currency,duration_minutes,notes,created_at,updated_at)
      values (request_id,provider,'Renamed Provider A',10000,'EGP',30,'Pagination quote',stamped,stamped) returning id into quote_id;
    insert into pg_temp.marketplace_page_fixtures values (request_id,quote_id,null);
  end loop;
end;
$pagination_fixtures$;

set local role authenticated;
do $feed_and_quote_pagination$
declare
  page jsonb;
  next_page jsonb;
  expected uuid[];
  actual uuid[];
begin
  page := public.get_marketplace_feed();
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'items') = 20 and page -> 'has_more' = 'true'::jsonb,
    'feed defaults to20, never materializes all matching listings');
  page := public.get_marketplace_feed(null,null,50);
  next_page := public.get_marketplace_feed((page #>> '{items,49,published_at}')::timestamptz,(page #>> '{items,49,request_id}')::uuid,50);
  select pg_catalog.array_agg(request_id order by request_id desc) into expected from pg_temp.marketplace_page_fixtures;
  select pg_catalog.array_agg((value ->> 'request_id')::uuid order by position) into actual
    from pg_catalog.jsonb_array_elements((page -> 'items') || (next_page -> 'items')) with ordinality as item(value,position);
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'items') = 50 and page -> 'has_more' = 'true'::jsonb
    and pg_catalog.jsonb_array_length(next_page -> 'items') = 2 and next_page -> 'has_more' = 'false'::jsonb
    and actual = expected,'feed equal-time UUID keyset returns all52 exactly once across50+2');
  page := public.get_provider_quotes();
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'items') = 20 and page -> 'has_more' = 'true'::jsonb,
    'provider quotes default to20');
  page := public.get_provider_quotes(null,null,50);
  next_page := public.get_provider_quotes((page #>> '{items,49,quote,created_at}')::timestamptz,(page #>> '{items,49,quote,id}')::uuid,50);
  select pg_catalog.array_agg(quote_id order by quote_id desc) into expected from pg_temp.marketplace_page_fixtures;
  select pg_catalog.array_agg((value #>> '{quote,id}')::uuid order by position) into actual
    from pg_catalog.jsonb_array_elements((page -> 'items') || (next_page -> 'items')) with ordinality as item(value,position)
    where (value #>> '{quote,id}')::uuid in (select quote_id from pg_temp.marketplace_page_fixtures);
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'items') = 50 and page -> 'has_more' = 'true'::jsonb
    and actual = expected,'provider quote keyset uses quote.created_at/id, not listing timestamps or updated terms');
end;
$feed_and_quote_pagination$;

set local role postgres;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
do $pagination_jobs$
declare
  fixture record;
  created_job uuid;
  stamped timestamptz := pg_catalog.current_setting('marketplace_test.page_time')::timestamptz + interval '1 second';
begin
  for fixture in select * from pg_temp.marketplace_page_fixtures loop
    insert into public.service_jobs (request_id,quote_id,customer_id,provider_id,provider_name,amount_minor,currency,
      duration_minutes,notes,quote_revision,disclosure_consented_at,created_at,updated_at)
    values (fixture.request_id,fixture.quote_id,auth.uid(),pg_catalog.current_setting('marketplace_test.provider_a')::uuid,
      'Renamed Provider A',10000,'EGP',30,'Pagination quote',1,stamped,stamped,stamped) returning id into created_job;
    update pg_temp.marketplace_page_fixtures set job_id = created_job where request_id = fixture.request_id;
  end loop;
end;
$pagination_jobs$;

set local role authenticated;
do $job_pagination$
declare
  page jsonb;
  next_page jsonb;
  expected uuid[];
  actual uuid[];
begin
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(public.get_service_jobs() -> 'items') = 20,'job page defaults to20');
  page := public.get_service_jobs(null,null,50);
  next_page := public.get_service_jobs((page #>> '{items,49,created_at}')::timestamptz,(page #>> '{items,49,id}')::uuid,50);
  select pg_catalog.array_agg(job_id order by job_id desc) into expected from pg_temp.marketplace_page_fixtures;
  select pg_catalog.array_agg((value ->> 'id')::uuid order by position) into actual
    from pg_catalog.jsonb_array_elements((page -> 'items') || (next_page -> 'items')) with ordinality as item(value,position)
    where (value ->> 'id')::uuid in (select job_id from pg_temp.marketplace_page_fixtures);
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'items') = 50 and page -> 'has_more' = 'true'::jsonb
    and actual = expected and not exists (select 1 from pg_catalog.jsonb_array_elements(page -> 'items') as item(value)
      where pg_catalog.jsonb_array_length(value -> 'history') <> 1 or value -> 'preferred_at' <> 'null'::jsonb),
    'job equal-time UUID keyset is bounded, distinct, participant-scoped, with initial histories and nullable preferred time');
end;
$job_pagination$;

set local role postgres;
create temporary table marketplace_comparison_fixtures (quote_id uuid) on commit drop;
grant select on pg_temp.marketplace_comparison_fixtures to authenticated;
do $comparison_fixtures$
declare
  customer uuid := pg_catalog.current_setting('marketplace_test.customer_a')::uuid;
  category uuid := pg_catalog.current_setting('marketplace_test.category')::uuid;
  request_id uuid := pg_catalog.gen_random_uuid();
  provider uuid;
  path text;
  verification jsonb;
  quote_id uuid;
  stamped timestamptz := pg_catalog.current_setting('marketplace_test.page_time')::timestamptz;
  index_number integer;
begin
  perform pg_temp.marketplace_login(customer);
  perform pg_temp.marketplace_request(request_id);
  perform public.publish_request_listing(request_id,'Public comparison pagination','Cairo',true);
  perform pg_catalog.set_config('marketplace_test.comparison_request',request_id::text,true);
  for index_number in 1..52 loop
    provider := pg_catalog.gen_random_uuid();
    insert into auth.users (id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values (provider,'authenticated','authenticated','marketplace-page-' || provider::text || '@example.invalid',
        '{"provider":"email","providers":["email"]}'::jsonb,'{"full_name":"Page Provider","role":"provider"}'::jsonb,now(),now());
    perform pg_temp.marketplace_login(provider);
    perform public.save_provider_onboarding(provider,'Pagination-only provider fixture for SQL checks.',array[category],array['Cairo'],
      '[{"weekday":1,"start_minute":0,"end_minute":60}]'::jsonb);
    path := provider::text || '/' || pg_catalog.replace(pg_catalog.gen_random_uuid()::text,'-','') || '.jpg';
    insert into storage.objects (bucket_id,name,owner_id,metadata)
      values ('provider-verification',path,provider::text,'{"mimetype":"image/jpeg","size":1}'::jsonb);
    verification := public.submit_provider_verification(provider,path,true);
    perform public.review_provider_verification((verification #>> '{verification,id}')::uuid,'verified',null,'rollback-reviewer');
    insert into public.provider_quotes (request_id,provider_id,provider_name,amount_minor,currency,duration_minutes,notes,created_at,updated_at)
      values (request_id,provider,'Page Provider',10000 + index_number,'EGP',30,'',stamped,stamped) returning id into quote_id;
    insert into pg_temp.marketplace_comparison_fixtures values (quote_id);
  end loop;
end;
$comparison_fixtures$;
select pg_temp.marketplace_login(pg_catalog.current_setting('marketplace_test.customer_a')::uuid);
set local role authenticated;
do $comparison_pagination$
declare
  request_id uuid := pg_catalog.current_setting('marketplace_test.comparison_request')::uuid;
  page jsonb;
  next_page jsonb;
  expected uuid[];
  actual uuid[];
begin
  page := public.get_customer_quotes(request_id);
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'quotes') = 20 and page -> 'has_more' = 'true'::jsonb,
    'customer quote comparison is bounded at default20, not an unbounded nested aggregate');
  page := public.get_customer_quotes(request_id,null,null,50);
  next_page := public.get_customer_quotes(request_id,(page #>> '{quotes,49,created_at}')::timestamptz,(page #>> '{quotes,49,id}')::uuid,50);
  select pg_catalog.array_agg(quote_id order by quote_id desc) into expected from pg_temp.marketplace_comparison_fixtures;
  select pg_catalog.array_agg((value ->> 'id')::uuid order by position) into actual
    from pg_catalog.jsonb_array_elements((page -> 'quotes') || (next_page -> 'quotes')) with ordinality as item(value,position);
  perform pg_temp.marketplace_assert(pg_catalog.jsonb_array_length(page -> 'quotes') = 50 and page -> 'has_more' = 'true'::jsonb
    and pg_catalog.jsonb_array_length(next_page -> 'quotes') = 2 and next_page -> 'has_more' = 'false'::jsonb and actual = expected,
    'comparison equal-time quote UUID keyset returns52 exactly once across50+2');
end;
$comparison_pagination$;

set local role postgres;

-- Exercise the same validation used by the whole migration. Every intentional
-- drift lives in an expected-error subtransaction and is rolled back on failure.
select salahly_private.validate_marketplace_integrity();
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    create policy unexpected_marketplace_access on public.provider_quotes for select to public using (true);
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Unexpected RLS policies on marketplace/request tables. No changes have been committed.');
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    create policy unexpected_request_access on public.service_requests for select to authenticated using (true);
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Unexpected RLS policies on marketplace/request tables. No changes have been committed.');
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    alter table public.provider_quotes drop constraint provider_quotes_amount_minor_check;
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Unexpected marketplace table constraints: provider_quotes. No changes have been committed.');
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    drop index public.provider_quotes_one_accepted_idx;
    create unique index provider_quotes_one_accepted_idx on public.provider_quotes(id) where status = 'accepted';
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Unexpected accepted-quote uniqueness index. No changes have been committed.');
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    alter table public.service_jobs disable trigger salahly_service_job_guard;
    update public.service_jobs set amount_minor = amount_minor + 1
      where id = (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid;
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Inconsistent persisted marketplace assignment/terms. No changes have been committed.');
select pg_temp.marketplace_expect_error($probe$
  do $drift$ begin
    alter table public.job_status_history disable trigger salahly_job_status_history_guard;
    delete from public.job_status_history
      where job_id = (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid and status = 'selected';
    perform salahly_private.validate_marketplace_integrity();
  end; $drift$;
$probe$,'P0001','Inconsistent persisted marketplace history. No changes have been committed.');
select salahly_private.validate_marketplace_integrity();

do $complete$
begin
  perform pg_temp.marketplace_assert((select pg_catalog.count(*) from public.service_jobs
    where request_id = pg_catalog.current_setting('marketplace_test.request_main')::uuid) = 1
    and (select pg_catalog.count(*) from public.provider_quotes where request_id = pg_catalog.current_setting('marketplace_test.request_main')::uuid
      and status = 'accepted') = 1 and (select pg_catalog.count(*) from public.job_status_history
        where job_id = (pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid) = 5,
    'all adversarial writes/retries preserved one accepted quote, one job, and five immutable main lifecycle events');
  perform pg_temp.marketplace_assert(salahly_private.service_job_snapshot((pg_catalog.current_setting('marketplace_test.job')::jsonb ->> 'id')::uuid)
    = pg_catalog.current_setting('marketplace_test.completed_job')::jsonb,
    'final canonical main job is unchanged by isolation, ACL, history, integrity, and pagination probes');
  perform pg_temp.marketplace_assert(not exists (select 1 from pg_catalog.pg_trigger where tgname in (
    'salahly_provider_quote_guard','salahly_service_job_guard','salahly_service_job_write','salahly_job_status_history_guard'
  ) and tgenabled <> 'O'),'all temporarily bypassed fixture guards restored');
  raise notice 'PASS: all Salahly quotes and jobs authorization/lifecycle SQL checks passed; rolling back every fixture.';
end;
$complete$;
rollback;
