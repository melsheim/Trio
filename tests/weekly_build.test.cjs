const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Execute the actual script embedded in the published workflow, with API fixtures.
const workflow = fs.readFileSync(`${__dirname}/../.github/workflows/weekly_build.yml`, 'utf8');
const script = workflow.split('          script: |\n')[1].split('\n').map(line => line.slice(12)).join('\n');
const baseRun = {
  id: 1, event: 'workflow_dispatch', head_branch: 'dev',
  created_at: '2026-11-22T16:00:00Z', status: 'completed', conclusion: 'success',
  run_attempt: 1, html_url: 'https://github.com/melsheim/Trio/actions/runs/1'
};
const uploaded = [{name: 'Build', conclusion: 'success', steps: [
  {name: 'Fastlane upload to TestFlight', conclusion: 'success'}
]}];
async function execute({runs = [], jobs = {}, checkOnly = false, disabled = false,
  now = '2026-11-22T17:00:00Z'} = {}) {
  const calls = [], failures = [], reports = [];
  class FixedDate extends Date {
    constructor(...args) { super(...(args.length ? args : [now])); }
  }
  const summary = {addHeading() {return this;}, addRaw(message) {reports.push(message); return this;}, async write() {}};
  const listWorkflowRuns = () => {}, listJobsForWorkflowRun = () => {};
  const github = {
    rest: {actions: {listWorkflowRuns, listJobsForWorkflowRun,
      async createWorkflowDispatch(args) {calls.push({type: 'dispatch', ...args});}}},
    async paginate(fn, args) {
      if (fn === listWorkflowRuns) {
        assert.equal(args.branch, 'dev');
        assert.equal(args.workflow_id, 'build_trio.yml');
        return runs;
      }
      return jobs[args.run_id] || [];
    },
    async request(route, args) {calls.push({type: 'retry', route, ...args});}
  };
  const context = vm.createContext({github, Date: FixedDate, Intl,
    context: {repo: {owner: 'melsheim', repo: 'Trio'}, payload: {repository: {default_branch: 'dev'}}},
    process: {env: {CHECK_ONLY: String(checkOnly), SCHEDULED_BUILD: disabled ? 'false' : ''}},
    core: {info() {}, summary, setFailed(message) {failures.push(message);}}
  });
  await new vm.Script(`(async () => {${script}\n})()`).runInContext(context);
  return {calls, failures, reports};
}

test('a missed Sunday trigger starts an actual build on the default branch', async () => {
  const result = await execute();
  assert.equal(result.calls.length, 1);
  assert.equal(result.calls[0].type, 'dispatch');
  assert.equal(result.calls[0].ref, 'dev');
});
test('backup does not duplicate an already uploaded TestFlight build', async () => {
  const result = await execute({runs: [baseRun], jobs: {1: uploaded}});
  assert.equal(result.calls.length, 0);
  assert.match(result.reports[0], /already succeeded/);
});
test('queued build is left running and not duplicated', async () => {
  const result = await execute({runs: [{...baseRun, status: 'queued', conclusion: null}]});
  assert.equal(result.calls.length, 0);
  assert.match(result.reports[0], /already queued or running/);
});
test('runner allocation failure retries only the failed job', async () => {
  const result = await execute({runs: [{...baseRun, conclusion: 'failure', run_attempt: 2}],
    jobs: {1: [{id: 50, name: 'Build', conclusion: 'cancelled', steps: null}]}});
  assert.equal(result.calls.length, 1);
  assert.equal(result.calls[0].type, 'retry');
  assert.equal(result.calls[0].job_id, 50);
});
test('repeated runner failures stop after three attempts', async () => {
  const result = await execute({runs: [{...baseRun, conclusion: 'failure', run_attempt: 3}],
    jobs: {1: [{id: 50, name: 'Build', conclusion: 'cancelled', steps: null}]}});
  assert.equal(result.calls.length, 0);
  assert.match(result.failures[0], /three attempts/);
});
test('compiler/signing errors remain visible for review instead of looping', async () => {
  const result = await execute({runs: [{...baseRun, conclusion: 'failure'}],
    jobs: {1: [{id: 50, name: 'Build', conclusion: 'failure',
      steps: [{name: 'Fastlane Build & Archive', conclusion: 'failure'}]}]}});
  assert.equal(result.calls.length, 0);
  assert.match(result.failures[0], /needs review/);
});
test('expected no-change cancellation does not suppress the weekly build', async () => {
  const result = await execute({runs: [{...baseRun, event: 'schedule', conclusion: 'cancelled'}],
    jobs: {1: [{name: 'Cancel run when there is nothing to build', conclusion: 'cancelled'},
      {name: 'Build', conclusion: 'skipped'}]}});
  assert.equal(result.calls[0]?.type, 'dispatch');
});
test('a manually cancelled build stays cancelled', async () => {
  const result = await execute({runs: [{...baseRun, conclusion: 'cancelled'}],
    jobs: {1: [{name: 'Build', conclusion: 'cancelled', steps: []}]}});
  assert.equal(result.calls.length, 0);
  assert.match(result.failures[0], /leaving it stopped/);
});
test('dry run performs no writes for either dispatch or retry', async () => {
  const fresh = await execute({checkOnly: true});
  const retry = await execute({checkOnly: true, runs: [{...baseRun, conclusion: 'failure'}],
    jobs: {1: [{id: 50, name: 'Build', conclusion: 'cancelled', steps: null}]}});
  assert.equal(fresh.calls.length + retry.calls.length, 0);
  assert.match(fresh.reports[0], /would start/);
  assert.match(retry.reports[0], /would retry/);
});
test('Monday catches a missed Sunday and ignores prior-week uploads and other branches', async () => {
  const result = await execute({now: '2026-11-23T17:00:00Z', runs: [
    {...baseRun, created_at: '2026-11-22T06:30:00Z'}, // Still Saturday in Pacific.
    {...baseRun, id: 2, head_branch: 'brian/ui'}
  ], jobs: {1: uploaded, 2: uploaded}});
  assert.equal(result.calls[0]?.type, 'dispatch');
  assert.match(result.reports[0], /2026-11-22/);
});
test('successful upload still counts if subsequent artifact cleanup failed', async () => {
  const result = await execute({runs: [{...baseRun, conclusion: 'failure'}], jobs: {1: uploaded}});
  assert.equal(result.calls.length, 0);
  assert.match(result.reports[0], /already succeeded/);
});
test('the explicit automatic-build opt-out is respected', async () => {
  const result = await execute({disabled: true});
  assert.equal(result.calls.length, 0);
  assert.match(result.reports[0], /disabled/);
});
test('Pacific daylight-saving transition retains the same Sunday week boundary', async () => {
  const result = await execute({now: '2027-03-15T14:17:00Z', checkOnly: true});
  assert.match(result.reports[0], /2027-03-14/);
});
