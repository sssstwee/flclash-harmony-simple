'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const gate = require('../../.github/scripts/dot-package-gate.cjs');
const SHA = 'a'.repeat(40);
const BASE_SHA = 'e23d459ce3290eb2f130933bcddcb4c7654133d0';
const BRANCH = 'dot/harmony-auto-adapt-20261014-0519';
const REPOSITORY = 'sssstwee/flclash-harmony-simple';
const step = (name, conclusion = 'success') => ({ name, conclusion });

function fixture() {
  const buildSteps = ['Verify source snapshot', 'Check generated files', 'Analyze', 'Test'].map(name => step(name));
  buildSteps.push(...['Set up Go bootstrap', 'Set up HarmonyOS Go',
    'Build unsigned HarmonyOS packages', 'Checksums', 'Upload packages'].map(name => step(name, 'skipped')));
  const nativeSteps = ['Verify source snapshot',
    'Test network observer and VPN lifecycle with in-memory APIs',
    'Test bounded native recovery with race detection',
    'Compile shared core integration for host tests',
    'Check native formatting'].map(name => step(name));
  const state = {
    context: { eventName: 'workflow_dispatch', ref: `refs/heads/${BRANCH}`, sha: SHA,
      runId: 222, repo: { owner: 'sssstwee', repo: 'flclash-harmony-simple' }, payload: {} },
    env: { REQUEST_PACKAGE: 'true', EXPECTED_SHA: SHA, VALIDATION_RUN_ID: '111', GITHUB_RUN_ATTEMPT: '1' },
    ref: SHA,
    currentPr: { number: 4, state: 'open', merged: false,
      head: { ref: BRANCH, sha: SHA, repo: { full_name: REPOSITORY } },
      base: { ref: 'codex/harmony-audit-fixes-github', sha: BASE_SHA, repo: { full_name: REPOSITORY } } },
    prior: { id: 111, run_attempt: 1, event: 'workflow_dispatch', head_branch: BRANCH, head_sha: SHA,
      status: 'completed', conclusion: 'success', path: '.github/workflows/harmony-simple.yml',
      repository: { full_name: REPOSITORY }, head_repository: { full_name: REPOSITORY },
      pull_requests: [{ number: 4, head: { ref: BRANCH, sha: SHA },
        base: { ref: 'codex/harmony-audit-fixes-github', sha: BASE_SHA } }] },
    jobs: [
      { name: 'secrets-scan', steps: [step('Verify source snapshot'), step('Check for committed secrets')] },
      { name: 'changes', steps: [step('Verify source snapshot')] },
      { name: 'backend', steps: [step('Verify source snapshot'), step('Run npm run check')] },
      { name: 'native-tests', steps: nativeSteps },
      { name: 'build', steps: buildSteps },
    ].map(job => ({ ...job, status: 'completed', conclusion: 'success' })),
    artifacts: 0,
    comparison: { status: 'ahead', merge_base_commit: { sha: BASE_SHA }, files: [{ filename: 'lib/main.dart' }] },
    outputs: {},
    messages: [],
    apiCalls: [],
  };
  const response = (name, value) => async args => {
    state.apiCalls.push({ name, args });
    return { data: value() };
  };
  state.github = {
    rest: {
      git: { getRef: response('getRef', () => ({ object: { sha: state.ref } })) },
      actions: {
        getWorkflowRun: response('getWorkflowRun', () => state.prior),
        getWorkflowRunAttempt: response('getWorkflowRunAttempt', () => state.prior),
        listJobsForWorkflowRunAttempt: 'attemptJobs',
        listJobsForWorkflowRun: 'jobs',
        listWorkflowRunArtifacts: response('artifacts', () => ({ total_count: state.artifacts })),
      },
      pulls: { get: response('getPr', () => state.currentPr) },
      repos: { compareCommits: response('compare', () => state.comparison) },
    },
    paginate: async (method, args) => {
      assert.ok(['jobs', 'attemptJobs'].includes(method));
      if (method === 'jobs') assert.equal(args.filter, 'latest');
      else assert.equal(args.attempt_number, 1);
      state.apiCalls.push({ name: 'jobs', args });
      return state.jobs;
    },
  };
  state.core = { setOutput: (key, value) => { state.outputs[key] = value; },
    info: message => { state.messages.push(message); } };
  return state;
}

function job(state, name) { return state.jobs.find(item => item.name === name); }
function prWithSkippedBackend(state) {
  state.prior.event = 'pull_request';
  job(state, 'backend').conclusion = 'skipped';
  job(state, 'backend').steps = [];
}

for (const [name, change, enabled, isolated] of [
  ['manual packaging after exact-head validation', () => {}, true, true],
  ['PR4 exact-head validation with successful backend', s => { s.prior.event = 'pull_request'; }, true, true],
  ['PR4 with unchanged reviewed backend', prWithSkippedBackend, true, true],
  ['manual validation remains package-free', s => { s.env.REQUEST_PACKAGE = 'false'; }, false, false],
  ['automatic dot PR never packages', s => {
    s.context.eventName = 'pull_request'; s.context.ref = 'refs/pull/4/merge';
    s.context.payload = { pull_request: { head: { ref: BRANCH } } };
    s.env.REQUEST_PACKAGE = ''; s.env.EXPECTED_SHA = '';
  }, false, false],
  ['PR2 remains package-free', s => {
    s.context.eventName = 'pull_request'; s.context.ref = 'refs/pull/2/merge';
    s.context.payload = { pull_request: { head: { ref: 'codex/harmony-audit-fixes-github' } } };
    s.env.REQUEST_PACKAGE = '';
  }, false, false],
  ['dot-named tag remains package-free without explicit request', s => {
    s.context.ref = `refs/tags/${BRANCH}`; s.env.REQUEST_PACKAGE = '';
  }, false, false],
  ['existing main behavior preserved', s => {
    s.context.eventName = 'push'; s.context.ref = 'refs/heads/main'; s.env.REQUEST_PACKAGE = '';
  }, true, false],
]) {
  test(name, async () => {
    const state = fixture(); change(state); await gate(state);
    assert.equal(state.outputs.enabled, String(enabled));
    assert.equal(state.outputs.isolated, String(isolated));
    if (isolated) {
      assert.equal(state.outputs.source_ref, `refs/heads/${BRANCH}`);
      assert.equal(state.outputs.validation_run_id, '111');
      assert.equal(state.outputs.validation_attempt, '1');
      assert.equal(state.outputs.package_attempt, '1');
      assert.equal(state.outputs.artifact, `dot-harmony-auto-adapt-${SHA.slice(0, 12)}`);
      assert.equal(state.outputs.upload_path, 'dot-package/');
      assert.equal(state.outputs.sha, SHA);
    } else if (state.context.eventName !== 'workflow_dispatch') {
      assert.equal(state.apiCalls.length, 0);
    }
  });
}

for (const [name, change] of [
  ['package request on another branch', s => { s.context.ref = 'refs/heads/main'; }],
  ['package request from another repository', s => { s.context.repo.owner = 'other'; }],
  ['package request from a tag', s => { s.context.ref = `refs/tags/${BRANCH}`; }],
  ['missing SHA', s => { s.env.EXPECTED_SHA = ''; }],
  ['abbreviated SHA', s => { s.env.EXPECTED_SHA = 'a'.repeat(12); }],
  ['wrong dispatch SHA', s => { s.env.EXPECTED_SHA = 'b'.repeat(40); }],
  ['branch moved since dispatch', s => { s.ref = 'b'.repeat(40); }],
  ['missing prior run', s => { s.env.VALIDATION_RUN_ID = ''; }],
  ['invalid prior run', s => { s.env.VALIDATION_RUN_ID = '111; command'; }],
  ['same run as validation', s => { s.env.VALIDATION_RUN_ID = '222'; }],
  ['wrong prior event', s => { s.prior.event = 'push'; }],
  ['wrong prior branch', s => { s.prior.head_branch = 'cursor/parallel'; }],
  ['wrong prior SHA', s => { s.prior.head_sha = 'b'.repeat(40); }],
  ['failed prior run', s => { s.prior.conclusion = 'failure'; }],
  ['incomplete prior run', s => { s.prior.status = 'in_progress'; }],
  ['wrong prior workflow', s => { s.prior.path = '.github/workflows/other.yml'; }],
  ['foreign prior repo', s => { s.prior.repository.full_name = 'other/repo'; }],
  ['foreign prior head repo', s => { s.prior.head_repository.full_name = 'other/repo'; }],
  ['wrong PR number', s => { s.prior.event = 'pull_request'; s.prior.pull_requests[0].number = 3; }],
  ['wrong PR base snapshot', s => { s.prior.event = 'pull_request'; s.prior.pull_requests[0].base.sha = 'b'.repeat(40); }],
  ['missing native job', s => { s.jobs = s.jobs.filter(j => j.name !== 'native-tests'); }],
  ['duplicate build job', s => { s.jobs.push(job(s, 'build')); }],
  ['skipped native job', s => { job(s, 'native-tests').conclusion = 'skipped'; }],
  ['missing native consistency', s => { job(s, 'native-tests').steps.pop(); }],
  ['skipped app tests', s => { job(s, 'build').steps.find(x => x.name === 'Test').conclusion = 'skipped'; }],
  ['missing strict generation', s => { job(s, 'build').steps.find(x => x.name === 'Check generated files').conclusion = 'skipped'; }],
  ['prior packaging run', s => { job(s, 'build').steps.find(x => x.name === 'Build unsigned HarmonyOS packages').conclusion = 'success'; }],
  ['prior artifacts', s => { s.artifacts = 1; }],
  ['manual backend skipped', s => { job(s, 'backend').conclusion = 'skipped'; }],
  ['failed backend', s => { job(s, 'backend').conclusion = 'failure'; }],
  ['skipped backend has changed file', s => { prWithSkippedBackend(s); s.comparison.files = [{ filename: 'backend/src/index.ts' }]; }],
  ['skipped backend has renamed file', s => { prWithSkippedBackend(s); s.comparison.files = [{ filename: 'archive/index.ts', previous_filename: 'backend/src/index.ts' }]; }],
  ['skipped backend comparison possibly truncated', s => { prWithSkippedBackend(s); s.comparison.files = Array(300).fill({ filename: 'lib/file.dart' }); }],
  ['skipped backend has wrong merge base', s => { prWithSkippedBackend(s); s.comparison.merge_base_commit.sha = 'b'.repeat(40); }],
  ['skipped backend comparison diverged', s => { prWithSkippedBackend(s); s.comparison.status = 'diverged'; }],
  ...['secrets-scan', 'changes', 'backend', 'native-tests', 'build'].map(name => [
    `missing exact source snapshot proof in ${name}`,
    s => { job(s, name).steps = job(s, name).steps.filter(x => x.name !== 'Verify source snapshot'); },
  ]),
]) {
  test(`rejects ${name}`, async () => {
    const state = fixture(); change(state);
    await assert.rejects(() => gate(state));
    assert.equal(state.outputs.enabled, 'false');
    assert.equal(state.outputs.isolated, 'false');
  });
}

test('API errors fail closed', async () => {
  const state = fixture();
  state.github.rest.actions.getWorkflowRun = async () => { throw new Error('API unavailable'); };
  await assert.rejects(() => gate(state), /API unavailable/);
  assert.equal(state.outputs.enabled, 'false');
});

function rerunFixture() {
  const state = fixture();
  state.context.eventName = 'pull_request';
  state.context.ref = 'refs/pull/4/merge';
  state.context.sha = 'f'.repeat(40); // Synthetic merge must never identify our package.
  state.context.payload = { pull_request: structuredClone(state.currentPr) };
  state.env.REQUEST_PACKAGE = '';
  state.env.EXPECTED_SHA = '';
  state.env.VALIDATION_RUN_ID = '';
  state.env.GITHUB_RUN_ATTEMPT = '2';
  state.prior.id = 222;
  state.prior.event = 'pull_request';
  return state;
}

test('PR4 build rerun packages source head only after immutable first-attempt success', async () => {
  const state = rerunFixture();
  await gate(state);
  assert.equal(state.outputs.enabled, 'true');
  assert.equal(state.outputs.isolated, 'true');
  assert.equal(state.outputs.sha, SHA);
  assert.equal(state.outputs.source_ref, `refs/heads/${BRANCH}`);
  assert.match(state.messages.at(-1), /Unsigned isolated packaging authorized/);
  assert.ok(state.messages.at(-1).includes(SHA));
  assert.equal(state.outputs.validation_run_id, '222');
  assert.equal(state.outputs.validation_attempt, '1');
  assert.equal(state.outputs.package_attempt, '2');
  const priorCall = state.apiCalls.find(call => call.name === 'getWorkflowRunAttempt');
  assert.equal(priorCall.args.run_id, '222');
  assert.equal(priorCall.args.attempt_number, 1);
  assert.ok(!state.apiCalls.some(call => call.name === 'getWorkflowRun'));
});

test('PR4 rerun uses first-attempt evidence even on a later packaging retry', async () => {
  const state = rerunFixture(); state.env.GITHUB_RUN_ATTEMPT = '3';
  await gate(state);
  assert.equal(state.outputs.validation_attempt, '1');
  assert.equal(state.outputs.package_attempt, '3');
});

test('PR4 attempt one always stays package-free', async () => {
  const state = rerunFixture(); state.env.GITHUB_RUN_ATTEMPT = '1';
  await gate(state);
  assert.equal(state.outputs.enabled, 'false');
  assert.equal(state.apiCalls.length, 0);
  assert.match(state.messages.at(-1), /first attempt: packaging disabled/);
});

for (const [name, change] of [
  ['first attempt explicit packaging input', s => { s.env.GITHUB_RUN_ATTEMPT = '1'; s.env.REQUEST_PACKAGE = 'true'; }],
  ['missing attempt proof', s => { delete s.env.GITHUB_RUN_ATTEMPT; }],
  ['invalid attempt proof', s => { s.env.GITHUB_RUN_ATTEMPT = '2junk'; }],
  ['zero attempt', s => { s.env.GITHUB_RUN_ATTEMPT = '0'; }],
  ['unsafe integer attempt', s => { s.env.GITHUB_RUN_ATTEMPT = '999999999999999999999'; }],
  ['wrong event PR number', s => { s.context.payload.pull_request.number = 3; }],
  ['wrong event ref', s => { s.context.ref = 'refs/pull/3/merge'; }],
  ['wrong event base', s => { s.context.payload.pull_request.base.sha = 'd'.repeat(40); }],
  ['foreign workflow repository', s => { s.context.repo.owner = 'foreign'; }],
  ['foreign source repository', s => { s.context.payload.pull_request.head.repo.full_name = 'foreign/repo'; }],
  ['foreign base repository', s => { s.context.payload.pull_request.base.repo.full_name = 'foreign/repo'; }],
  ['changed live head', s => { s.ref = 'd'.repeat(40); }],
  ['changed live PR head', s => { s.currentPr.head.sha = 'd'.repeat(40); }],
  ['changed live PR base', s => { s.currentPr.base.sha = 'd'.repeat(40); }],
  ['closed live PR', s => { s.currentPr.state = 'closed'; }],
  ['merged live PR', s => { s.currentPr.merged = true; }],
  ['wrong live PR number', s => { s.currentPr.number = 3; }],
  ['wrong live PR head ref', s => { s.currentPr.head.ref = 'cursor/parallel'; }],
  ['foreign live PR source', s => { s.currentPr.head.repo.full_name = 'foreign/repo'; }],
  ['wrong requested source SHA', s => { s.env.EXPECTED_SHA = 'd'.repeat(40); }],
  ['failed first attempt', s => { s.prior.conclusion = 'failure'; }],
  ['incomplete first attempt', s => { s.prior.status = 'in_progress'; }],
  ['first attempt API returned different run', s => { s.prior.id = 111; }],
  ['first attempt API returned second attempt', s => { s.prior.run_attempt = 2; }],
  ['missing first attempt number', s => { delete s.prior.run_attempt; }],
  ['first attempt returned synthetic merge SHA', s => { s.prior.head_sha = s.context.sha; }],
  ['first attempt had packaging', s => { job(s, 'build').steps.find(x => x.name === 'Upload packages').conclusion = 'success'; }],
  ['first attempt missing app proof', s => { job(s, 'build').steps.find(x => x.name === 'Check generated files').conclusion = 'skipped'; }],
  ['run already has artifact', s => { s.artifacts = 1; }],
]) {
  test(`rerun rejects ${name}`, async () => {
    const state = rerunFixture(); change(state);
    await assert.rejects(() => gate(state));
    assert.equal(state.outputs.enabled, 'false');
  });
}
