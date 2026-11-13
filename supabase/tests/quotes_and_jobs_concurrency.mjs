// Run through run_local.mjs --concurrency. This module deliberately has no DSN
// or standalone existing-database mode: fixtures COMMIT, then the runner drops
// the entire isolated database (immutable evidence must not be force-deleted).
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const quoteTerms = (amount) => [amount, 'EGP', 90, 'Local concurrency fixture terms.'];
const quoteSql = 'select public.save_provider_quote($1, $2, $3, $4, $5, $6) as value';
const acceptSql = 'select public.accept_provider_quote($1, $2, true) as value';
const transitionSql = 'select public.transition_service_job($1, $2, $3) as value';

async function rpc(client, sql, parameters) {
  const { rows } = await client.query(sql, parameters);
  assert.equal(rows.length, 1, 'RPC returns exactly one canonical result');
  return rows[0].value;
}

async function beginActor(client, user) {
  await client.query('begin');
  await client.query(`
    select set_config('request.jwt.claim.sub', $1, true),
      set_config('request.jwt.claims', $2, true)
  `, [user, JSON.stringify({ sub: user, role: 'authenticated' })]);
  await client.query('set local role authenticated');
}

async function asActor(client, user, operation) {
  await beginActor(client, user);
  try {
    const result = await operation(client);
    await client.query('commit');
    return result;
  } catch (error) {
    await client.query('rollback');
    throw error;
  }
}

async function readState(client, request) {
  return rpc(client, `
    select jsonb_build_object(
      'request', (select to_jsonb(r) from public.service_requests r where r.id = $1),
      'quotes', (select coalesce(jsonb_agg(to_jsonb(q) order by q.provider_id), '[]')
        from public.provider_quotes q where q.request_id = $1),
      'jobs', (select coalesce(jsonb_agg(to_jsonb(j)), '[]')
        from public.service_jobs j where j.request_id = $1),
      'history', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at, h.id), '[]')
        from public.job_status_history h
        join public.service_jobs j on j.id = h.job_id where j.request_id = $1)
    ) as value
  `, [request]);
}

function acceptedState(state, provider, terms) {
  assert.equal(state.request.status, 'assigned');
  assert.equal(state.request.cancelled_at, null);
  assert.equal(state.jobs.length, 1, 'one job per request');
  const accepted = state.quotes.filter((quote) => quote.status === 'accepted');
  assert.equal(accepted.length, 1, 'one accepted quote per request');
  const [quote] = accepted;
  const [job] = state.jobs;
  assert.equal(quote.provider_id, provider);
  assert.equal(job.provider_id, provider);
  assert.equal(job.quote_id, quote.id);
  assert.equal(job.request_id, state.request.id);
  assert.equal(job.customer_id, state.request.customer_id);
  assert.equal(job.quote_revision, quote.revision);
  assert.equal(quote.revision, 1);
  assert.deepEqual([quote.amount_minor, quote.currency, quote.duration_minutes, quote.notes], terms);
  assert.deepEqual([job.amount_minor, job.currency, job.duration_minutes, job.notes], terms);
  assert.equal(job.provider_name, quote.provider_name);
  assert.equal(job.status, 'selected');
  assert(state.quotes.filter((other) => other.id !== quote.id).every((other) => other.status === 'not_selected'));
  assert.equal(state.history.length, 1, 'acceptance appends exactly one selected event');
  const [event] = state.history;
  assert.equal(event.job_id, job.id);
  assert.equal(event.from_status, null);
  assert.equal(event.status, 'selected');
  assert.equal(event.actor_id, job.customer_id);
  assert.equal(event.created_at, job.created_at);
  assert.equal(event.created_at, job.updated_at);
  assert.equal(job.disclosure_consented_at, job.created_at);
}

export async function runConcurrency({ connect, lockEvents, observer }) {
  const firstClient = await connect('race-first');
  const secondClient = await connect('race-second');
  assert.notEqual(firstClient.processID, secondClient.processID, 'separate PostgreSQL backends, not a shared connection');
  assert.notEqual(firstClient.processID, observer.processID);
  assert.notEqual(secondClient.processID, observer.processID);
  const customer = randomUUID();
  const providers = [randomUUID(), randomUUID()];
  const category = randomUUID();
  let schedules = 0;

  // Await a real lock wait, not time passing. PostgreSQL emits log_lock_waits
  // only after the backend is queued; pg_blocking_pids independently verifies
  // the first transaction really blocks the second before we release it.
  async function race(label, first, second, expectedError) {
    let onWaiting;
    try {
      await beginActor(firstClient, first.user);
      const firstValue = await first.run(firstClient);
      await beginActor(secondClient, second.user);
      const blocked = new Promise((resolve) => {
        onWaiting = (pid) => { if (pid === secondClient.processID) resolve(); };
        lockEvents.on('waiting', onWaiting);
      });
      // Attach both handlers immediately: a deliberately rejected RPC must not
      // become an unhandled rejection while we are awaiting the lock barrier.
      const secondResult = second.run(secondClient).then(
        (value) => ({ value }), (error) => ({ error }),
      );
      await Promise.race([
        blocked,
        secondResult.then((result) => {
          throw new Error(`${label}: second RPC finished without a proven lock overlap: ${result.error?.message ?? 'success'}`);
        }),
      ]);
      const { rows: [waiting] } = await observer.query('select pg_blocking_pids($1) as blockers', [secondClient.processID]);
      assert(waiting.blockers.includes(firstClient.processID), `${label}: first backend must actually block second`);
      await firstClient.query('commit');
      const result = await secondResult;
      if (expectedError) {
        assert(result.error, `${label}: stale/losing operation must not report success`);
        assert.equal(result.error.code, 'P0001', `${label}: domain error, not deadlock/timeout/unique violation`);
        assert.equal(result.error.message, expectedError, label);
        await secondClient.query('rollback');
      } else {
        if (result.error) throw result.error;
        await secondClient.query('commit');
        assert.deepEqual(result.value, firstValue, `${label}: retry returns identical canonical result`);
      }
      schedules += 1;
      console.log(`PASS concurrency ${label}: backend ${secondClient.processID} blocked by ${firstClient.processID}; ${expectedError ?? 'identical retry'}`);
    } finally {
      if (onWaiting) lockEvents.off('waiting', onWaiting);
      // Release the first lock even on assertion failure before waiting for the
      // second transaction to roll back. Server-side timeouts bound failures.
      await firstClient.query('rollback');
      await secondClient.query('rollback');
    }
  }

  async function fixture() {
    const request = randomUUID();
    await asActor(observer, customer, async (client) => {
      await rpc(client, `select public.submit_service_request(
        $1, $2, 'Repair kitchen pipe', 'The kitchen pipe needs a local plumbing repair.',
        'Cairo', '12 Synthetic Street, apartment 4', null, '[]'::jsonb, true
      ) as value`, [request, category]);
      await rpc(client, 'select public.publish_request_listing($1, $2, $3, true) as value',
        [request, 'Kitchen plumbing repair needed.', 'Cairo']);
    });
    for (const [index, provider] of providers.entries()) {
      await asActor(observer, provider, (client) => rpc(client, quoteSql,
        [request, ...quoteTerms(25000 + index * 2000), 0]));
    }
    const state = await readState(observer, request);
    assert.equal(state.quotes.length, 2);
    assert(state.quotes.every((quote) => quote.status === 'pending' && quote.revision === 1));
    return { request, quotes: providers.map((provider) => state.quotes.find((quote) => quote.provider_id === provider)) };
  }

  const accept = (quote) => ({ user: customer, run: (client) => rpc(client, acceptSql, [quote.id, 1]) });
  const cancel = (request) => ({ user: customer, run: (client) => rpc(client,
    'select public.cancel_service_request($1) as value', [request]) });
  const revise = (request) => ({ user: providers[0], run: (client) => rpc(client,
    quoteSql, [request, ...quoteTerms(39000), 1]) });
  const withdraw = (quote) => ({ user: providers[0], run: (client) => rpc(client,
    'select public.withdraw_provider_quote($1, $2) as value', [quote.id, 1]) });

  try {
    for (const [user, role] of [[customer, 'customer'], ...providers.map((id) => [id, 'provider'])]) {
      await observer.query(`
        insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
        values ($1, 'authenticated', 'authenticated', $2, '{"provider":"email","providers":["email"]}', $3, now(), now())
      `, [user, `m7-race-${user}@example.invalid`, JSON.stringify({ full_name: 'Concurrency Fixture', role })]);
    }
    await observer.query(`
      insert into public.service_categories (id, slug, name_en, name_ar, description_en, description_ar, icon_key)
      values ($1, $2, 'Fixture Plumbing', 'Fixture Plumbing AR', 'Local fixture', 'Local fixture AR', 'plumbing')
    `, [category, `m7_race_${category}`]);
    for (const provider of providers) {
      await asActor(observer, provider, (client) => rpc(client, `select public.save_provider_onboarding(
        $1, 'Experienced local provider for concurrency verification.', $2::uuid[], array['Cairo'],
        '[{"weekday":1,"start_minute":480,"end_minute":1080}]'::jsonb
      ) as value`, [provider, [category]]));
      const document = `${provider}/${randomUUID().replaceAll('-', '')}.jpg`;
      await observer.query(`
        insert into storage.objects (bucket_id, name, owner_id, metadata)
        values ('provider-verification', $1, $2, '{"mimetype":"image/jpeg","size":1}')
      `, [document, provider]);
      const submitted = await asActor(observer, provider, (client) => rpc(client,
        'select public.submit_provider_verification($1, $2, true) as value', [provider, document]));
      await rpc(observer, 'select public.review_provider_verification($1, $2, null, $3) as value',
        [submitted.verification.id, 'verified', 'isolated-concurrency-fixture']);
    }

    for (const winner of [0, 1]) {
      const { request, quotes } = await fixture();
      await race(`accept provider ${winner + 1} / competing acceptance`, accept(quotes[winner]),
        accept(quotes[1 - winner]), 'marketplace.errors.status');
      acceptedState(await readState(observer, request), providers[winner], quoteTerms(25000 + winner * 2000));
    }

    {
      const { request, quotes } = await fixture();
      await race('accept / cancel request', accept(quotes[0]), cancel(request), 'requests.errors.status');
      acceptedState(await readState(observer, request), providers[0], quoteTerms(25000));
    }
    {
      const { request, quotes } = await fixture();
      await race('cancel request / accept', cancel(request), accept(quotes[0]), 'marketplace.errors.status');
      const state = await readState(observer, request);
      assert.equal(state.request.status, 'cancelled');
      assert(state.request.cancelled_at);
      assert.equal(state.jobs.length, 0);
      assert.equal(state.history.length, 0);
      assert(state.quotes.every((quote) => quote.status === 'cancelled'));
    }

    {
      const { request, quotes } = await fixture();
      await race('accept / revise price', accept(quotes[0]), revise(request), 'marketplace.errors.status');
      acceptedState(await readState(observer, request), providers[0], quoteTerms(25000));
    }
    {
      const { request, quotes } = await fixture();
      await race('revise price / accept stale revision', revise(request), accept(quotes[0]), 'marketplace.errors.conflict');
      const state = await readState(observer, request);
      assert.equal(state.request.status, 'open');
      assert.equal(state.jobs.length, 0, 'stale acceptance must not bind the customer to a new price');
      assert.equal(state.history.length, 0);
      const quote = state.quotes.find((entry) => entry.id === quotes[0].id);
      assert.equal(quote.amount_minor, 39000);
      assert.equal(quote.revision, 2);
      assert(state.quotes.every((entry) => entry.status === 'pending'));
    }

    {
      const { request, quotes } = await fixture();
      await race('accept / withdraw', accept(quotes[0]), withdraw(quotes[0]), 'marketplace.errors.status');
      acceptedState(await readState(observer, request), providers[0], quoteTerms(25000));
    }
    {
      const { request, quotes } = await fixture();
      await race('withdraw / accept', withdraw(quotes[0]), accept(quotes[0]), 'marketplace.errors.status');
      const state = await readState(observer, request);
      assert.equal(state.request.status, 'open');
      assert.equal(state.jobs.length, 0);
      assert.equal(state.history.length, 0);
      assert.equal(state.quotes.find((quote) => quote.id === quotes[0].id).status, 'withdrawn');
      assert.equal(state.quotes.find((quote) => quote.id === quotes[1].id).status, 'pending');
    }

    {
      const { request, quotes } = await fixture();
      await asActor(observer, customer, accept(quotes[0]).run);
      let state = await readState(observer, request);
      acceptedState(state, providers[0], quoteTerms(25000));
      const job = state.jobs[0].id;
      const advance = { user: providers[0], run: (client) => rpc(client, transitionSql, [job, 'selected', 'in_progress']) };
      await race('duplicate provider transition', advance, advance);
      state = await readState(observer, request);
      assert.equal(state.jobs[0].status, 'in_progress');
      assert.equal(state.history.length, 2, 'duplicate provider RPC appends only one event');
      assert.deepEqual(state.history.map((event) => [event.from_status, event.status]),
        [[null, 'selected'], ['selected', 'in_progress']]);
      assert.equal(state.history[1].actor_id, providers[0]);
      assert.equal(state.history[1].created_at, state.jobs[0].updated_at);

      await asActor(observer, providers[0], (client) => rpc(client, transitionSql, [job, 'in_progress', 'awaiting_confirmation']));
      const confirm = { user: customer, run: (client) => rpc(client, transitionSql, [job, 'awaiting_confirmation', 'completed']) };
      await race('duplicate customer completion', confirm, confirm);
      state = await readState(observer, request);
      assert.equal(state.jobs[0].status, 'completed');
      assert.equal(state.history.length, 4, 'duplicate completion appends only one event');
      assert.deepEqual(state.history.map((event) => [event.from_status, event.status]),
        [[null, 'selected'], ['selected', 'in_progress'], ['in_progress', 'awaiting_confirmation'], ['awaiting_confirmation', 'completed']]);
      assert.equal(state.history[3].actor_id, customer);
      assert.equal(state.history[3].created_at, state.jobs[0].updated_at);
    }
    assert.equal(schedules, 10);
    console.log('PASS concurrency invariants: unique acceptance/job, frozen terms, stale-price rejection, terminal competitors, and one history event per transition.');
    return schedules;
  } finally {
    await firstClient.end();
    await secondClient.end();
  }
}
