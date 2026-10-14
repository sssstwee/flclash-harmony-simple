'use strict';

const REPOSITORY_ID = '1415379213';
const REPOSITORIES = new Set([
  'sssstwee/flclash-harmony-simple',
  'sssstwee/xiaomao-ai-proxy',
]);
const BRANCH = 'dot/harmony-auto-adapt-20261014-0519';
const BASE_BRANCH = 'codex/harmony-audit-fixes-github';
const BASE_SHA = 'e23d459ce3290eb2f130933bcddcb4c7654133d0';
const WORKFLOW = '.github/workflows/harmony-simple.yml';
const PACKAGING_STEPS = [
  'Set up Go bootstrap',
  'Set up HarmonyOS Go',
  'Build unsigned HarmonyOS packages',
  'Checksums',
  'Upload packages',
];

function requireStep(job, name, conclusion = 'success') {
  if (!job.steps?.some(step => step.name === name && step.conclusion === conclusion)) {
    throw new Error(`Required ${job.name} step must be ${conclusion}: ${name}`);
  }
}

function requireJob(jobs, name) {
  const matches = jobs.filter(job => job.name === name);
  if (matches.length !== 1 || matches[0].status !== 'completed' ||
      matches[0].conclusion !== 'success') {
    throw new Error(`Required validation job did not pass: ${name}`);
  }
  return matches[0];
}

function positiveAttempt(value, label) {
  const text = String(value ?? '');
  if (!/^[1-9][0-9]*$/.test(text) || !Number.isSafeInteger(Number(text))) {
    throw new Error(`Missing or invalid ${label}`);
  }
  return Number(text);
}

function matchesPullRequest(pr, sha) {
  return pr?.number === 4 && pr.head?.ref === BRANCH && pr.head?.sha === sha &&
    pr.base?.ref === BASE_BRANCH && pr.base?.sha === BASE_SHA;
}

/** Read-only gate called by actions/github-script after exact-source checkout. */
module.exports = async function dotPackageGate({ github, context, core, env = process.env }) {
  const requested = env.REQUEST_PACKAGE === 'true';
  const payloadPr = context.payload.pull_request;
  const headRef = payloadPr?.head?.ref || '';
  const refName = context.ref.replace(/^refs\/(?:heads|tags)\//, '');
  const blocked = [BASE_BRANCH, BRANCH];
  const legacy = !blocked.includes(headRef) && !blocked.includes(refName);
  const repository = `${context.repo.owner}/${context.repo.repo}`;
  const ownRepo = REPOSITORIES.has(repository) &&
    String(env.GITHUB_REPOSITORY_ID || '') === REPOSITORY_ID;
  const ownManual = context.eventName === 'workflow_dispatch' && ownRepo &&
    context.ref === `refs/heads/${BRANCH}`;
  const dotPr = context.eventName === 'pull_request' && headRef === BRANCH;

  // Default closed. Only publish an enabled output after all applicable checks.
  core.setOutput('enabled', 'false');
  core.setOutput('isolated', 'false');
  core.setOutput('artifact', `xiaomao-ai-proxy-HarmonyOS-${context.sha}`);
  core.setOutput('upload_path', 'dist/');
  if (requested && !ownManual) {
    throw new Error('Explicit packaging inputs are restricted to the exact dot manual branch.');
  }
  let rerun = false;
  if (dotPr) {
    const attempt = positiveAttempt(env.GITHUB_RUN_ATTEMPT, 'GITHUB_RUN_ATTEMPT');
    if (attempt === 1) {
      core.info?.('Dot PR4 first attempt: packaging disabled; validation only.');
      return;
    }
    if (!ownRepo || context.ref !== 'refs/pull/4/merge' ||
        !matchesPullRequest(payloadPr, payloadPr.head?.sha) ||
        payloadPr.head?.repo?.full_name !== repository ||
        payloadPr.base?.repo?.full_name !== repository) {
      throw new Error('A rerun may package only the exact own-repository PR4 snapshot.');
    }
    rerun = true;
  }
  if (!ownManual && !rerun) {
    core.setOutput('enabled', legacy ? 'true' : 'false');
    return;
  }

  const packageAttempt = positiveAttempt(env.GITHUB_RUN_ATTEMPT, 'GITHUB_RUN_ATTEMPT');
  const sha = rerun ? payloadPr.head.sha : (env.EXPECTED_SHA || '');
  if (!/^[a-f0-9]{40}$/.test(sha) || (!rerun && sha !== context.sha)) {
    throw new Error('Source SHA must be the full exact PR head or dispatch commit.');
  }
  if (rerun && env.EXPECTED_SHA && env.EXPECTED_SHA !== sha) {
    throw new Error('Rerun expected_sha does not match the original PR head.');
  }
  const { data: currentRef } = await github.rest.git.getRef({
    ...context.repo, ref: `heads/${BRANCH}`,
  });
  if (currentRef.object.sha !== sha) {
    throw new Error('Dot branch moved; validate its new head before packaging.');
  }
  core.setOutput('sha', sha);
  core.setOutput('source_ref', `refs/heads/${BRANCH}`);
  core.setOutput('short_sha', sha.slice(0, 12));
  core.setOutput('package_attempt', String(packageAttempt));
  if (!requested && !rerun) return;

  const { data: currentPr } = await github.rest.pulls.get({
    ...context.repo, pull_number: 4,
  });
  if (currentPr.state !== 'open' || currentPr.merged === true ||
      !matchesPullRequest(currentPr, sha) ||
      currentPr.head?.repo?.full_name !== repository ||
      currentPr.base?.repo?.full_name !== repository) {
    throw new Error('PR4 must remain open on the exact reviewed branch, base and head.');
  }

  const runId = rerun ? String(context.runId) : (env.VALIDATION_RUN_ID || '');
  if (!/^[1-9][0-9]*$/.test(runId) || (!rerun && runId === String(context.runId))) {
    throw new Error('A separate validation run or proven first-attempt rerun is required.');
  }
  const { data: prior } = rerun
    ? await github.rest.actions.getWorkflowRunAttempt({
      ...context.repo, run_id: runId, attempt_number: 1,
    })
    : await github.rest.actions.getWorkflowRun({ ...context.repo, run_id: runId });
  const validationAttempt = positiveAttempt(prior.run_attempt, 'validation run attempt');
  if (!['workflow_dispatch', 'pull_request'].includes(prior.event) ||
      String(prior.id) !== runId || prior.head_branch !== BRANCH || prior.head_sha !== sha ||
      prior.status !== 'completed' || prior.conclusion !== 'success' ||
      prior.path !== WORKFLOW || prior.repository?.full_name !== repository ||
      prior.head_repository?.full_name !== repository ||
      (rerun && (prior.event !== 'pull_request' || validationAttempt !== 1 || packageAttempt <= 1))) {
    throw new Error('Validation must be a successful exact-head own-branch run attempt.');
  }
  if (prior.event === 'pull_request' &&
      !prior.pull_requests?.some(pr => matchesPullRequest(pr, sha))) {
    throw new Error('PR validation must be PR4 stacked on the reviewed PR2 snapshot.');
  }

  const jobs = rerun
    ? await github.paginate(github.rest.actions.listJobsForWorkflowRunAttempt, {
      ...context.repo, run_id: runId, attempt_number: 1, per_page: 100,
    })
    : await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
      ...context.repo, run_id: runId, filter: 'latest', per_page: 100,
    });
  const required = ['secrets-scan', 'changes', 'native-tests', 'build'];
  const verified = Object.fromEntries(required.map(name => [name, requireJob(jobs, name)]));
  for (const job of Object.values(verified)) requireStep(job, 'Verify source snapshot');

  const backendJobs = jobs.filter(job => job.name === 'backend');
  if (backendJobs.length !== 1 || backendJobs[0].status !== 'completed') {
    throw new Error('Missing or incomplete backend validation job.');
  }
  const backend = backendJobs[0];
  if (backend.conclusion === 'success') {
    requireStep(backend, 'Verify source snapshot');
    requireStep(backend, 'Run npm run check');
  } else if (backend.conclusion === 'skipped' && prior.event === 'pull_request') {
    const { data: comparison } = await github.rest.repos.compareCommits({
      ...context.repo, base: BASE_SHA, head: sha,
    });
    // REST comparisons expose at most 300 files: reject a possibly truncated proof.
    if (!['ahead', 'identical'].includes(comparison.status) ||
        comparison.merge_base_commit?.sha !== BASE_SHA ||
        !Array.isArray(comparison.files) || comparison.files.length >= 300 ||
        comparison.files.some(file => file.filename.startsWith('backend/') ||
          file.previous_filename?.startsWith('backend/'))) {
      throw new Error('Skipped backend lacks unchanged reviewed-baseline proof.');
    }
  } else {
    throw new Error('Backend validation must pass; only an unchanged PR may skip it.');
  }

  requireStep(verified['secrets-scan'], 'Check for committed secrets');
  for (const name of [
    'Test network observer and VPN lifecycle with in-memory APIs',
    'Test bounded native recovery with race detection',
    'Compile shared core integration for host tests',
    'Check native formatting',
  ]) requireStep(verified['native-tests'], name);
  for (const name of ['Check generated files', 'Analyze', 'Test']) {
    requireStep(verified.build, name);
  }
  for (const name of PACKAGING_STEPS) requireStep(verified.build, name, 'skipped');
  const { data: artifacts } = await github.rest.actions.listWorkflowRunArtifacts({
    ...context.repo, run_id: runId, per_page: 1,
  });
  if (artifacts.total_count !== 0) {
    throw new Error('Validation-only run unexpectedly produced artifacts.');
  }

  core.info?.(`Unsigned isolated packaging authorized: source ${sha}; ` +
    `validation run ${runId} attempt ${validationAttempt}; ` +
    `package run ${context.runId} attempt ${packageAttempt}.`);
  core.setOutput('validation_run_id', runId);
  core.setOutput('validation_attempt', String(validationAttempt));
  core.setOutput('enabled', 'true');
  core.setOutput('isolated', 'true');
  core.setOutput('artifact', `xiaomao-ai-proxy-${sha.slice(0, 12)}`);
  core.setOutput('upload_path', 'dot-package/');
};
