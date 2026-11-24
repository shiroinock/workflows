// Collects what Claude's review said in the owner's repositories since a given time, for
// rule-harvest.yml to sort into static-rule candidates. Reads only; writes one JSON file.
//
//   node scripts/harvest-findings.mjs <out.json>
//
// Environment:
//   GH_TOKEN   token that can read the repositories (a fine-grained token with read access to
//              pull requests, issues and contents reaches the private ones; GITHUB_TOKEN only
//              the public ones)
//   OWNER      the account whose repositories are read
//   GH_REPO    this repository, where the open candidates (label ルール候補) live
//   SINCE_DAYS how far back to read (default 7)
//
// The output holds code from private repositories too. It stays on the runner: never upload it
// as an artifact or print it to the log, since this repository is public.

import { writeFileSync, appendFileSync } from 'node:fs';

const out = process.argv[2];
const { GH_TOKEN, OWNER, GH_REPO, GITHUB_OUTPUT } = process.env;
if (!out || !GH_TOKEN || !OWNER || !GH_REPO) {
  console.error('usage: GH_TOKEN=… OWNER=… GH_REPO=… node scripts/harvest-findings.mjs <out.json>');
  process.exit(2);
}
const sinceDays = Number(process.env.SINCE_DAYS || 7);
const since = new Date(Date.now() - sinceDays * 24 * 60 * 60 * 1000).toISOString();

const REVIEW_WORKFLOW = '.github/workflows/claude-code-review.yml';
const CLAUDE = 'claude[bot]';
const NITS_MARKER = /^<!-- claude-review-nits pr=(\d+) -->/;
const CANDIDATE_MARKER = /<!-- rule-candidate key=([a-z0-9-]+) -->/;
// Lint, Renovate and pnpm settings worth showing, so the sorting can tell which built-in rules and
// settings are already on.
const CONFIG_FILES = [
  'biome.json',
  'biome.jsonc',
  '.oxlintrc.json',
  'ruff.toml',
  '.ruff.toml',
  'pyproject.toml',
  'Cargo.toml',
  'clippy.toml',
  '.shellcheckrc',
  '.swiftlint.yml',
  'package.json',
  'pnpm-workspace.yaml',
  'renovate.json',
  'renovate.json5',
  '.github/renovate.json',
  '.github/renovate.json5',
  '.renovaterc',
  '.renovaterc.json',
  '.github/static-rules-off',
];
const MAX_CONFIG = 4000;
const MAX_BODY = 2000;
const MAX_HUNK = 1200;

const clip = (s, n) => (s && s.length > n ? `${s.slice(0, n)}…` : (s ?? ''));

async function api(path, { allow404 = false } = {}) {
  const res = await fetch(path.startsWith('https://') ? path : `https://api.github.com/${path}`, {
    headers: {
      Authorization: `Bearer ${GH_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (allow404 && res.status === 404) return { data: null, next: null };
  if (!res.ok) throw new Error(`${res.status} ${path}: ${await res.text()}`);
  const next = res.headers.get('link')?.match(/<([^>]+)>;\s*rel="next"/)?.[1] ?? null;
  return { data: await res.json(), next };
}

async function all(path, opts) {
  const items = [];
  let url = path;
  while (url) {
    const { data, next } = await api(url, opts);
    if (data === null) return null;
    items.push(...data);
    url = next;
  }
  return items;
}

async function repositories() {
  // A token of the owner lists the private repositories too; GITHUB_TOKEN cannot call /user.
  let repos;
  try {
    repos = await all('user/repos?affiliation=owner&per_page=100');
  } catch {
    repos = await all(`users/${OWNER}/repos?type=owner&per_page=100`);
  }
  return repos.filter((r) => r.owner.login === OWNER && !r.archived && !r.fork);
}

async function fileText(repo, path) {
  const { data } = await api(`repos/${repo}/contents/${path}`, { allow404: true });
  if (!data || Array.isArray(data) || data.encoding !== 'base64') return null;
  return Buffer.from(data.content, 'base64').toString('utf8');
}

async function rootFiles(repo, branch) {
  const { data } = await api(`repos/${repo}/git/trees/${branch}`, { allow404: true });
  return data ? data.tree.map((t) => (t.type === 'tree' ? `${t.path}/` : t.path)) : [];
}

// Names only: enough to tell whether a CI step is already there without the workflows' text.
async function workflowFiles(repo) {
  const { data } = await api(`repos/${repo}/contents/.github/workflows`, { allow404: true });
  return Array.isArray(data) ? data.filter((f) => f.type === 'file').map((f) => f.name) : [];
}

const result = { since, sinceDays, repos: [], items: [], openCandidates: [] };

for (const r of await repositories()) {
  const repo = r.full_name;
  const review = await api(`repos/${repo}/contents/${REVIEW_WORKFLOW}`, { allow404: true });
  if (!review.data) continue;

  const info = {
    repo,
    private: r.private,
    language: r.language,
    rootFiles: await rootFiles(repo, r.default_branch),
    workflows: await workflowFiles(repo),
    configs: {},
  };
  for (const f of CONFIG_FILES) {
    const text = await fileText(repo, f);
    if (text !== null) info.configs[f] = clip(text, MAX_CONFIG);
  }
  result.repos.push(info);

  // Findings: Claude's line comments. They are the ones that had to be fixed before merging.
  const comments = (await all(`repos/${repo}/pulls/comments?since=${since}&per_page=100`)) ?? [];
  for (const c of comments) {
    if (c.user?.login !== CLAUDE || c.in_reply_to_id) continue;
    result.items.push({
      kind: 'finding',
      repo,
      private: r.private,
      pr: Number(c.pull_request_url.split('/').pop()),
      path: c.path,
      line: c.line ?? c.original_line ?? null,
      url: c.html_url,
      body: clip(c.body, MAX_BODY),
      diffHunk: clip(c.diff_hunk, MAX_HUNK),
    });
  }

  // Nits: the minor findings the review collects in the issue labelled あとで直す.
  const issues = (await all(`repos/${repo}/issues?labels=あとで直す&state=all&since=${since}&per_page=100`)) ?? [];
  for (const issue of issues) {
    if (issue.pull_request) continue;
    const nits = (await all(`repos/${repo}/issues/${issue.number}/comments?since=${since}&per_page=100`)) ?? [];
    for (const c of nits) {
      const m = c.body?.match(NITS_MARKER);
      if (!m) continue;
      for (const line of c.body.split('\n')) {
        if (!line.startsWith('- [')) continue;
        result.items.push({
          kind: 'nit',
          repo,
          private: r.private,
          pr: Number(m[1]),
          url: c.html_url,
          body: clip(line, MAX_BODY),
        });
      }
    }
  }
}

// The candidates already open here, so the same pattern lands on the same issue.
const open = (await all(`repos/${GH_REPO}/issues?labels=ルール候補&state=open&per_page=100`)) ?? [];
for (const issue of open) {
  const key = issue.body?.match(CANDIDATE_MARKER)?.[1];
  if (key) result.openCandidates.push({ key, number: issue.number, title: issue.title });
}

writeFileSync(out, JSON.stringify(result, null, 2));
// Counts only: the items themselves may come from private repositories.
console.log(
  `${result.repos.length} 個のリポジトリから、${since} 以降の指摘を ${result.items.length} 件集めた(開いている候補 ${result.openCandidates.length} 件)`,
);
if (GITHUB_OUTPUT) appendFileSync(GITHUB_OUTPUT, `count=${result.items.length}\n`);
