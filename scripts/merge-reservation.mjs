#!/usr/bin/env node
// Turns on auto-merge (merge commit) for reviewed PRs, but only once they point at main.
//
//   node scripts/merge-reservation.mjs   (needs gh, GH_TOKEN and GH_REPO; BASE_BRANCH and CI_WORKFLOW optional)
//
// The reusable workflow .github/workflows/merge-reservation.yml in shiroinock/workflows runs it when the label is added, when a PR's base
// changes, when a PR is merged, and every 10 minutes. A stacked PR (one whose base is another PR's
// branch) has no required checks on its base, so `gh pr merge --auto` would merge it there at once.
// This waits until GitHub retargets it to main after the PR below it is merged.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const LABEL = 'マージ予約';
export const MARKER = '<!-- merge-reservation -->';

/** GITHUB_TOKEN cannot merge changes to workflows, so those PRs are merged by hand. */
export function touchesWorkflows(files = []) {
  return files.some((f) => /^\.github\/workflows\//.test(f.path ?? f));
}

export function hasLabel(pr, label = LABEL) {
  return (pr.labels ?? []).some((l) => (l.name ?? l) === label);
}

/**
 * What to do with one PR. `enable` turns on auto-merge; `wait` and `skip` leave it alone, and
 * `manual` asks for a merge by hand. `reason` says why, and how to move on when it waits.
 */
export function decide(pr, { base = 'main', label = LABEL } = {}) {
  if (!hasLabel(pr, label)) return { action: 'skip', reason: `「${label}」が付いていない。` };
  if (pr.state && pr.state !== 'OPEN') return { action: 'skip', reason: '開いていない。' };
  if (pr.isCrossRepository) {
    return {
      action: 'manual',
      reason:
        'フォークからの PR は、レビューのあとに積まれたコミットまで予約に乗るので、自動では予約しない。手でマージする。',
    };
  }
  if (pr.baseRefName !== base) {
    return {
      action: 'wait',
      reason: `向き先が ${pr.baseRefName}。下の PR がマージされて ${base} に付け替わったら予約する。`,
    };
  }
  if (pr.isDraft) {
    return { action: 'wait', reason: '下書き。「Ready for review」にしたら予約する。' };
  }
  if (pr.autoMergeRequest) return { action: 'skip', reason: '予約済み。' };
  if (touchesWorkflows(pr.files)) {
    return {
      action: 'manual',
      reason:
        '.github/workflows を変えている。GITHUB_TOKEN ではマージできないので、検査が通ったら手でマージする（gh pr merge --merge）。',
    };
  }
  return { action: 'enable', reason: `${base} に向いている。自動マージを入れる。` };
}

const FIELDS = 'number,title,state,baseRefName,isDraft,isCrossRepository,autoMergeRequest,labels';

function defaultGh(args) {
  return execFileSync('gh', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
}

/**
 * Looks at every open PR with the label. Every trigger runs the same scan, so a PR missed by one
 * event (GitHub sends none for what GITHUB_TOKEN merged) is picked up by the next one.
 */
export function run({
  gh = defaultGh,
  base = 'main',
  label = LABEL,
  log = console.log,
  logError = console.error,
} = {}) {
  // `--label` goes through search, which can miss a label added a moment ago (the very event that
  // started this run). List every open PR and pick the labelled ones here instead.
  const prs = JSON.parse(gh(['pr', 'list', '--state', 'open', '--limit', '200', '--json', FIELDS]));
  const results = [];
  for (const listed of prs.filter((p) => hasLabel(p, label))) {
    // One PR that keeps failing (a conflict, say) must not hold back the others or CI on main.
    try {
      // Read the PR again right before acting: the base may have changed since the list.
      const pr = JSON.parse(gh(['pr', 'view', String(listed.number), '--json', `${FIELDS},files`]));
      const { action, reason } = decide(pr, { base, label });
      log(`#${pr.number} ${pr.title}：${reason}`);
      if (action === 'enable') {
        gh(['pr', 'merge', String(pr.number), '--auto', '--merge']);
      } else if (action === 'manual') {
        const comments = JSON.parse(gh(['pr', 'view', String(pr.number), '--json', 'comments']));
        if (!comments.comments.some((c) => c.body.includes(MARKER))) {
          gh([
            'pr',
            'comment',
            String(pr.number),
            '--body',
            `${MARKER}\n「${label}」が付いていますが、自動マージは入れません：${reason}`,
          ]);
        }
      }
      results.push({ number: pr.number, action });
    } catch (err) {
      logError(`#${listed.number}：失敗した。次の PR へ進む。${err.message}`);
      results.push({ number: listed.number, action: 'error' });
    }
  }
  return results;
}

/**
 * A merge done with GITHUB_TOKEN starts no workflow, so CI on main would not run for it. Starts CI
 * on main by hand (workflow_dispatch is the one event GITHUB_TOKEN may start) when the head of
 * main has no CI run yet.
 */
export function ensureBaseCi({ gh = defaultGh, base = 'main', workflow = 'ci.yml', log = console.log } = {}) {
  if (!workflow) return false;
  const sha = gh(['api', `repos/{owner}/{repo}/commits/${base}`, '--jq', '.sha']).trim();
  const runs = JSON.parse(
    gh([
      'run',
      'list',
      '--workflow',
      workflow,
      '--commit',
      sha,
      '--limit',
      '1',
      '--json',
      'status',
    ]),
  );
  if (runs.length > 0) return false;
  log(`${base} の先頭 ${sha.slice(0, 7)} に CI が走っていないので、走らせる。`);
  gh(['workflow', 'run', workflow, '--ref', base]);
  return true;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const base = process.env.BASE_BRANCH || 'main';
  let failed = false;
  try {
    failed = run({ base }).some((r) => r.action === 'error');
  } catch (err) {
    console.error(err.message);
    failed = true;
  }
  // Runs even when a PR failed above, so a merge GITHUB_TOKEN made still gets CI on main.
  try {
    ensureBaseCi({ base, workflow: process.env.CI_WORKFLOW ?? '' });
  } catch (err) {
    console.error(err.message);
    failed = true;
  }
  if (failed) process.exitCode = 1;
}
