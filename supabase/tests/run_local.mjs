#!/usr/bin/env node
// Native PostgreSQL only. Dependencies live outside the app; no DSN/env credentials
// are accepted. Every run creates and destroys its own loopback-only cluster.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { EventEmitter, once } from 'node:events';
import { createWriteStream } from 'node:fs';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const migrations = [
  '202610160001_salahly_foundation.sql',
  '202610180001_provider_onboarding.sql',
  '202610310001_service_requests.sql',
  '202611090001_quotes_and_jobs.sql',
  '202611110001_smart_matching.sql',
];
const suites = [
  ['foundation_rls.sql', 'PASS: all Salahly foundation checks passed'],
  ['provider_onboarding_rls.sql', 'PASS: all Salahly provider onboarding authorization/Storage SQL checks passed'],
  ['service_requests_rls.sql', 'PASS: all Salahly service request authorization/Storage SQL checks passed'],
  ['quotes_and_jobs_rls.sql', 'PASS: all Salahly quotes and jobs'],
  ['smart_matching_rls.sql', 'PASS: all Salahly smart matching'],
];

// Deliberately a SQL stand-in, not an Auth/Storage service emulator. Generated
// path_tokens matters: BEFORE UPDATE triggers see its not-yet-computed NEW value.
const bootstrap = String.raw`
begin;
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create schema auth authorization postgres;
create schema storage authorization postgres;
revoke create on schema public from public;
grant usage on schema auth, storage, public to anon, authenticated, service_role;

create table auth.users (
  id uuid primary key,
  aud text,
  role text,
  email text,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  created_at timestamptz,
  updated_at timestamptz
);
create function auth.uid() returns uuid language sql stable as $function$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$function$;
create function auth.jwt() returns jsonb language sql stable as $function$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb;
$function$;

create table storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  owner_id text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  public boolean not null default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  owner_id text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata jsonb,
  user_metadata jsonb,
  version text,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  unique (bucket_id, name)
);
alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.buckets, storage.objects
  to anon, authenticated, service_role;
-- Model Supabase's broad defaults so missing application REVOKEs cannot hide.
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to anon, authenticated, service_role;
commit;
`;

const identifier = (value) => `"${value.replaceAll('"', '""')}"`;

async function snapshot(client) {
  const { rows } = await client.query(`
    select n.nspname, c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('auth', 'public', 'storage') and c.relkind = 'r'
    order by n.nspname, c.relname
  `);
  const result = {};
  for (const { nspname, relname } of rows) {
    const table = `${identifier(nspname)}.${identifier(relname)}`;
    const { rows: digest } = await client.query(`
      select count(*)::integer as count,
        md5(coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text)::text, '[]')) as hash
      from ${table} t
    `);
    result[table] = digest[0];
  }
  return result;
}

async function runSql(client, source, label, finalNotice, verbose) {
  const notices = [];
  const onNotice = (notice) => {
    notices.push(notice.message);
    if (verbose) console.log(`${label}: ${notice.message}`);
  };
  client.on('notice', onNotice);
  try {
    const results = await client.query(source);
    const last = Array.isArray(results) ? results.at(-1) : results;
    assert.equal(last.command, finalNotice ? 'ROLLBACK' : 'COMMIT', `${label}: transaction terminator`);
    if (finalNotice) {
      assert(notices.some((notice) => notice.startsWith(finalNotice)), `${label}: final PASS notice missing`);
    }
    const passes = notices.filter((notice) => /^PASS\b/.test(notice)).length;
    console.log(`PASS ${label}${finalNotice ? `: ${passes} PASS notices, ROLLBACK` : ': COMMIT'}`);
    return passes;
  } catch (error) {
    if (error.position) {
      const line = source.slice(0, Number(error.position) - 1).split('\n').length;
      console.error(`${label}:${line}`);
    }
    if (error.where) console.error(error.where);
    throw new Error(`${label}: ${error.code ?? 'assertion'}: ${error.message}`, { cause: error });
  } finally {
    client.off('notice', onNotice);
  }
}

async function availablePort() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function main() {
  const { values } = parseArgs({ options: {
    deps: { type: 'string' },
    through: { type: 'string', default: 'm8' },
    suite: { type: 'string', multiple: true },
    concurrency: { type: 'boolean', default: false },
    verbose: { type: 'boolean', default: false },
    help: { type: 'boolean', default: false },
  } });
  if (values.help) {
    console.log('Usage: node supabase/tests/run_local.mjs --deps <external npm prefix> [--through m6|m7|m8] [--suite <filename> ...] [--concurrency] [--verbose]');
    console.log('External-only setup: npm install --prefix <external npm prefix> --ignore-scripts --no-audit --no-fund embedded-postgres@18.6.0-beta.19 pg@8.23.1');
    console.log('Default: M8 fresh + ordered migration replay, all five rollback suites in both phases.');
    console.log('--through m6/m7 explicitly verifies only the first three/four milestones.');
    console.log('--suite explicitly selects a subset of the known rollback suites; omitted means all.');
    console.log('--concurrency additionally commits synthetic fixtures inside the disposable local database.');
    console.log('No remote connection or existing-cluster mode. PostgreSQL children stop before exit.');
    return;
  }
  assert(values.deps, '--deps must name the external npm installation prefix');
  assert(['m6', 'm7', 'm8'].includes(values.through), '--through must be m6, m7, or m8');
  assert(!values.concurrency || values.through !== 'm6', '--concurrency requires M7 or M8');
  const count = values.through === 'm6' ? 3 : values.through === 'm7' ? 4 : 5;
  const availableSuites = suites.slice(0, count);
  if (values.suite) {
    assert.equal(new Set(values.suite).size, values.suite.length, 'duplicate --suite argument');
    assert(values.suite.every((name) => availableSuites.some(([known]) => known === name)), 'unknown --suite argument');
    console.log(`EXPLICIT SUITE SUBSET: ${values.suite.join(', ')}`);
  }
  // Read complete files once. A missing selected milestone is never silently skipped.
  const migrationFiles = await Promise.all(migrations.slice(0, count).map(async (name) => ({
    name, source: await readFile(path.join(testDirectory, '..', 'migrations', name), 'utf8'),
  })));
  const suiteFiles = await Promise.all(availableSuites.filter(([name]) => !values.suite || values.suite.includes(name)).map(async ([name, finalNotice]) => ({
    name, finalNotice, source: await readFile(path.join(testDirectory, name), 'utf8'),
  })));
  const externalRequire = createRequire(path.join(path.resolve(values.deps), 'package.json'));
  const { Client } = externalRequire('pg');
  const platform = process.platform === 'win32' ? 'windows' : process.platform;
  const binaries = await import(pathToFileURL(externalRequire.resolve(`@embedded-postgres/${platform}-${process.arch}`)).href);
  const tempRoot = path.join(tmpdir(), 'kilo');
  assert((await stat(tempRoot)).isDirectory(), 'The existing OS temp/kilo parent is required');
  const runDirectory = await mkdtemp(path.join(tempRoot, 'salahly-sql-'));
  const dataDirectory = path.join(runDirectory, 'data');
  const passwordFile = path.join(runDirectory, 'init-password');
  const logPath = path.join(runDirectory, 'postgres.log');
  const log = createWriteStream(logPath);
  const lockEvents = new EventEmitter();
  const password = randomBytes(32).toString('hex');
  const port = await availablePort();
  const environment = { ...process.env, TEMP: runDirectory, TMP: runDirectory, TMPDIR: runDirectory, LC_MESSAGES: 'C' };
  // Do not inherit connection/service configuration from a developer shell.
  for (const key of Object.keys(environment)) if (/^PG/i.test(key)) delete environment[key];
  let postmaster;
  let postmasterExit;
  let administrator;
  const clients = new Set();
  const database = `salahly_verify_${randomUUID().replaceAll('-', '')}`;
  let databaseCreated = false;
  const cleanupErrors = [];

  const execute = (executable, args) => new Promise((resolve, reject) => {
    const child = spawn(executable, args, { env: environment, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (chunk) => log.write(chunk));
    child.stderr.on('data', (chunk) => log.write(chunk));
    child.once('error', reject);
    child.once('close', (code) => code === 0 ? resolve() : reject(new Error(`${path.basename(executable)} exited ${code}; see ${logPath}`)));
  });

  const connect = async (name, target = database) => {
    const client = new Client({
      host: '127.0.0.1', port, user: 'postgres', password, database: target,
      ssl: false, application_name: `salahly-local-${name}`, connectionTimeoutMillis: 10000,
      options: '-c timezone=UTC -c client_min_messages=notice',
      statement_timeout: 30000, lock_timeout: 15000, idle_in_transaction_session_timeout: 30000,
    });
    clients.add(client);
    client.on('error', (error) => console.error(`PostgreSQL client ${name}: ${error.message}`));
    client.once('end', () => clients.delete(client));
    await client.connect();
    return client;
  };

  try {
    await writeFile(passwordFile, `${password}\n`, { mode: 0o600, flag: 'wx' });
    await execute(binaries.initdb, [
      '-D', dataDirectory, '-U', 'postgres', `--pwfile=${passwordFile}`,
      '--auth=scram-sha-256', '--encoding=UTF8', '--locale=C',
    ]);
    await rm(passwordFile);
    await new Promise((resolve, reject) => {
      postmaster = spawn(binaries.postgres, [
        '-D', dataDirectory, '-h', '127.0.0.1', '-p', String(port),
        '-c', 'unix_socket_directories=', '-c', 'log_line_prefix=salahly-pg[%p] ',
        '-c', 'log_lock_waits=on', '-c', 'deadlock_timeout=50ms',
      ], { env: environment, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      postmasterExit = new Promise((done) => postmaster.once('close', done));
      let pending = '';
      const onData = (chunk) => {
        log.write(chunk);
        pending += chunk.toString();
        const lines = pending.split('\n');
        pending = lines.pop();
        for (const line of lines) {
          if (line.includes('database system is ready to accept connections')) resolve();
          const match = /salahly-pg\[(\d+)\].*still waiting for/.exec(line);
          if (match) lockEvents.emit('waiting', Number(match[1]));
        }
      };
      postmaster.stdout.on('data', onData);
      postmaster.stderr.on('data', onData);
      postmaster.once('error', reject);
      postmaster.once('close', (code) => reject(new Error(`PostgreSQL exited ${code}; see ${logPath}`)));
    });
    administrator = await connect('administrator', 'postgres');
    const { rows: [version] } = await administrator.query('select version() as version, host(inet_server_addr()) as host');
    assert.equal(version.host, '127.0.0.1');
    console.log(`LOCAL ${version.version}; port ${port}; native independent connections`);
    await administrator.query(`create database ${identifier(database)}`);
    databaseCreated = true;
    const client = await connect('suites');
    await runSql(client, bootstrap, 'Supabase-shaped bootstrap', null, values.verbose);
    const results = [];
    let preserved;
    let races = 0;
    for (const phase of ['fresh', 'rerun']) {
      for (const migration of migrationFiles) {
        await runSql(client, migration.source, `${phase}/${migration.name}`, null, values.verbose);
      }
      if (preserved) {
        assert.deepEqual(await snapshot(client), preserved, 'ordered migration replay must preserve every stored row');
        console.log('PASS rerun: all stored rows unchanged');
      }
      for (const suite of suiteFiles) {
        const before = await snapshot(client);
        const passes = await runSql(client, suite.source, `${phase}/${suite.name}`, suite.finalNotice, values.verbose);
        assert.deepEqual(await snapshot(client), before, `${suite.name}: rollback must restore all stored rows`);
        results.push({ phase, suite: suite.name, passes });
      }
      if (phase === 'fresh') {
        if (values.concurrency) {
          const { runConcurrency } = await import('./quotes_and_jobs_concurrency.mjs');
          races = await runConcurrency({ connect, lockEvents, observer: client });
          if (count === 5) {
            // Reuse ONLY the committed synthetic M7 actors in this new database.
            // The existing digest now proves populated M8/config replay too.
            await client.query(`
              do $m8_replay$ declare fixture record; begin
                for fixture in select user_id, category_id from public.provider_skills loop
                  perform pg_catalog.set_config('request.jwt.claim.sub', fixture.user_id::text, true);
                  set local role authenticated;
                  perform public.save_provider_matching_profile(true, 30.04, 31.24,
                    pg_catalog.jsonb_build_object(fixture.category_id::text, 4), 0, true);
                  set local role postgres;
                end loop;
                perform salahly_private.configure_matching_rules(1, 7, 5, 3, 2, 25, 8);
                if (select count(*) from public.provider_matching_profiles) <> 2
                  or not exists (select 1 from public.matching_rules where revision = 2 and distance_weight = 7
                    and rating_weight = 5 and availability_weight = 3 and experience_weight = 2
                    and distance_scale_km = 25 and experience_cap_years = 8) then
                  raise exception 'FAIL: populated M8 replay fixtures';
                end if;
              end; $m8_replay$;
            `);
            console.log('PASS M8 populated replay fixtures: two consented profiles and non-default versioned rules.');
          }
        }
        preserved = await snapshot(client);
      }
    }
    console.log(`SUMMARY: ${count} fresh migrations + ${count} ordered reruns; ${results.length} rollback suite runs; ${results.reduce((sum, result) => sum + result.passes, 0)} PASS notices; ${races} deterministic concurrency schedules.`);
    console.log('LIMITS: SQL/JWT-GUC/Storage-metadata simulation only; not hosted Auth, PostgREST, uploaded bytes, signed URLs, or HTTP concurrency.');
  } finally {
    for (const client of [...clients].filter((client) => client !== administrator)) {
      try { await client.end(); } catch (error) { cleanupErrors.push(error); }
    }
    if (administrator) {
      if (databaseCreated) {
        try { await administrator.query(`drop database ${identifier(database)} with (force)`); }
        catch (error) { cleanupErrors.push(error); }
      }
      try { await administrator.end(); } catch (error) { cleanupErrors.push(error); }
    }
    if (postmaster?.pid && postmaster.exitCode === null) {
      try {
        await execute(binaries.pg_ctl, ['-D', dataDirectory, '-m', 'fast', '-w', '-t', '15', 'stop']);
      } catch (error) {
        cleanupErrors.push(error);
        if (process.platform === 'win32') await execute('taskkill', ['/pid', String(postmaster.pid), '/t', '/f']);
        else postmaster.kill('SIGKILL');
      }
      await postmasterExit;
    }
    try {
      await rm(passwordFile, { force: true });
      await rm(dataDirectory, { recursive: true, force: true });
    } catch (error) { cleanupErrors.push(error); }
    await new Promise((resolve) => log.end(resolve));
    console.log(`CLEANUP: ${cleanupErrors.length ? 'failed (see errors)' : 'isolated database/cluster removed; PostgreSQL stopped'}. Diagnostic log: ${logPath}`);
    if (cleanupErrors.length) throw new AggregateError(cleanupErrors, 'Local PostgreSQL cleanup failed');
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
