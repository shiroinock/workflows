# 自分の GitHub リポジトリに共通の設定(ベースライン)を入れる。何度実行してもよい。
#   使い方: repo-baseline              # フォークとアーカイブ、トピック no-baseline のものを除く全リポジトリ
#           repo-baseline repo1 repo2  # 指定したリポジトリだけ(トピックは見ない)
#   新しく作るときは repo-new(gh repo create のあとにこれを流す)を使う。
#
# 入れるもの:
#   - 共通のワークフロー:templates/ のうち、まだ無いもの(Renovate の設定もここ)。あるものは書き換えない。
#     dept.yml は、ルートに dept が読めるロックファイル(pnpm-lock.yaml か package-lock.json)がある
#     リポジトリにだけ入れる(無いと毎回失敗するため)。
#     非公開のリポジトリでは、merge-reservation.yml の schedule を外す(Actions の無料枠を食うため)。
#     空のリポジトリには最初のコミットとして入れ、中身のあるリポジトリには PR を出す。
#     リポジトリの .github/baseline-skip に書いたテンプレート(1行に1つ、templates/ のファイル名)と、
#     閉じた(マージしなかった)PR に入っていたファイルは、もう入れない。
#   - シークレット CLAUDE_CODE_OAUTH_TOKEN:無ければ 1Password から入れる(op が使えるときだけ)。
#   - マージ方法はマージコミットのみ(スカッシュとリベースは無効)
#   - 自動マージを許可、マージ後にブランチを自動削除、「Update branch」ボタンを出す
#   - シークレットスキャンと push protection(使えないプランでは飛ばす)
#   - Dependabot の脆弱性アラートをオン。自動の修正 PR はオフ(修正の PR は Renovate が出す)
#   - ルールセット「main を守る」: デフォルトブランチの削除と force push を禁止し、PR を必須にする
#     (承認は 0 人、マージコミットのみ)。同名のルールセットが既にあれば触らない。
#     空のリポジトリに最初のコミットを入れたあとで作る。
#
# 環境変数:
#   OWNER                 対象のアカウント(既定 shiroinock)
#   TEMPLATES_DIR         テンプレートの場所(nix のパッケージが、同じ版の templates/ を渡す)
#   CLAUDE_TOKEN_OP_REF   CLAUDE_CODE_OAUTH_TOKEN の 1Password の参照
#   BASELINE_HIDE_PRIVATE 1 なら、非公開のリポジトリの名前とエラーの中身を出さない(公開のログ向け)
#   GH_TOKEN              gh のトークン(手元では gh auth のものが使われる)。ワークフローを書くので
#                         workflow のスコープ(fine-grained なら Workflows の書き込み、シークレットを
#                         確かめるのに Secrets の読み取り)が要る
#
# API のエラーは「無い」「空」とはみなさない。404(と空のリポジトリの 409)だけを「無い」「空」とし、
# ほかのエラーではその手順を飛ばす。失敗が1つでもあれば、最後に 1 で終わる。
set +e  # 失敗は1件ずつ報告して先へ進む
failures=0
fail() { echo "$1"; failures=$((failures + 1)); }

OWNER="${OWNER:-shiroinock}"
TEMPLATES_DIR="${TEMPLATES_DIR:?TEMPLATES_DIR が無い(nix run github:shiroinock/workflows#repo-baseline で動かす)}"
CLAUDE_TOKEN_OP_REF="${CLAUDE_TOKEN_OP_REF:-op://AI-Shared/6kqqyn7mxdgvbx64e5gqisp74a/credential}"
RULESET_NAME="main を守る"
BRANCH="chore/common-workflows"
SKIP_TOPIC="no-baseline"

if [ "$#" -gt 0 ]; then
  repos=("$@")
else
  if ! list=$(gh repo list "$OWNER" --limit 1000 --json name,isFork,isArchived,repositoryTopics \
    --jq ".[] | select(.isFork|not) | select(.isArchived|not)
      | select([.repositoryTopics[]?.name] | index(\"$SKIP_TOPIC\") | not) | .name"); then
    echo "リポジトリの一覧を読めなかった(トークンを確かめる)"
    exit 1
  fi
  mapfile -t repos <<<"$list"
fi

ruleset_body=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge"]
    } }
  ]
}
JSON
)

# Where each template goes in a repository.
dest_of() {
  case "$1" in
    renovate.json) echo renovate.json ;;
    *.yml) echo ".github/workflows/$1" ;;
  esac
}

# The template as it goes into this repository.
render() { # <template file> <private>
  if [ "$2" = true ] && [ "$(basename "$1")" = merge-reservation.yml ]; then
    # Drop the schedule, its cron line and the comments just above it; a private repository pays
    # for every run.
    awk '
      /^  #/ { held = held $0 "\n"; next }
      /^  schedule:/ { held = ""; skip = 1; next }
      skip && /^    - cron:/ { next }
      { printf "%s", held; held = ""; skip = 0; print }
      END { printf "%s", held }' "$1"
  else
    cat "$1"
  fi
}

# 0: the API answered; 1: it answered with the given status (the "not there" case); 2: any other
# error (rate limit, 5xx, no permission), which must not be read as "not there".
probe() { # <api path> <status that means not there>
  local err
  err=$(gh api "$1" --silent 2>&1) && return 0
  case "$err" in *"HTTP $2"*) return 1 ;; esac
  return 2
}

exists() { # <repo> <path> <ref>: 0 there, 1 not there, 2 could not tell
  probe "repos/$1/contents/$2?ref=$3" 404
}

# Renovate reads any of these; one is enough.
has_renovate() { # <repo> <ref>: 0 there, 1 not there, 2 could not tell
  local f r unknown=0
  for f in renovate.json renovate.json5 .github/renovate.json .github/renovate.json5 .renovaterc .renovaterc.json; do
    exists "$1" "$f" "$2"
    r=$?
    [ "$r" = 0 ] && return 0
    [ "$r" = 2 ] && unknown=1
  done
  [ "$unknown" = 1 ] && return 2
  return 1
}

# dept reads these lockfiles at the root; without one its job fails every time.
has_dept_lockfile() { # <repo> <ref>: 0 there, 1 not there, 2 could not tell
  local f r unknown=0
  for f in pnpm-lock.yaml package-lock.json; do
    exists "$1" "$f" "$2"
    r=$?
    [ "$r" = 0 ] && return 0
    [ "$r" = 2 ] && unknown=1
  done
  [ "$unknown" = 1 ] && return 2
  return 1
}

# Templates this repository declined: listed in .github/baseline-skip on the default branch, or in
# a PR from $BRANCH that was closed without merging. One path per line. Status 2: could not tell.
declined() { # <repo> <ref>
  local text r prs
  text=$(gh api "repos/$1/contents/.github/baseline-skip?ref=$2" -H "Accept: application/vnd.github.raw" 2>&1)
  r=$?
  if [ "$r" = 0 ]; then
    sed 's/#.*//; s/[[:space:]]//g' <<<"$text" | grep . | while IFS= read -r name; do dest_of "$name"; done
  elif [[ "$text" != *"HTTP 404"* ]]; then
    return 2
  fi
  prs=$(gh pr list -R "$1" --head "$BRANCH" --state closed --limit 100 --json mergedAt,files \
    --jq '.[] | select(.mergedAt == null) | .files[].path' 2>/dev/null) || return 2
  printf '%s\n' "$prs" | grep .
  return 0
}

workflows_step() { # <full> <private> <default branch> <empty>
  local full=$1 private=$2 default=$3 empty=$4 t dest r skip=""
  local files=()
  if [ "$empty" = false ]; then
    if ! skip=$(declined "$full" "$default"); then
      fail "   共通のワークフロー: 断ったものを読めなかったので飛ばす"
      return
    fi
  fi
  for t in "$TEMPLATES_DIR"/*; do
    dest=$(dest_of "$(basename "$t")")
    [ -n "$dest" ] || continue
    # An empty repository has no lockfile yet; a later run puts it in once there is one.
    if [ "$(basename "$t")" = dept.yml ]; then
      [ "$empty" = true ] && continue
      has_dept_lockfile "$full" "$default"
      r=$?
      [ "$r" = 1 ] && continue
      if [ "$r" = 2 ]; then
        fail "   共通のワークフロー: dept が読めるロックファイルがあるか確かめられなかったので飛ばす"
        return
      fi
    fi
    if [ "$empty" = false ]; then
      grep -qxF "$dest" <<<"$skip" && continue
      if [ "$dest" = renovate.json ]; then
        has_renovate "$full" "$default"
      else
        exists "$full" "$dest" "$default"
      fi
      r=$?
      [ "$r" = 0 ] && continue
      if [ "$r" = 2 ]; then
        fail "   共通のワークフロー: $dest があるか確かめられなかったので飛ばす"
        return
      fi
    fi
    files+=("$t")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo "   共通のワークフロー: そろっている"
    return
  fi
  local names
  names=$(for t in "${files[@]}"; do basename "$t"; done | paste -sd, -)

  if [ "$empty" = true ]; then
    # An empty repository has no branch to open a PR against, and the Git data API refuses it;
    # the contents API makes the first commit on the default branch.
    local ok=0
    for t in "${files[@]}"; do
      dest=$(dest_of "$(basename "$t")")
      render "$t" "$private" | base64 -w0 | jq -Rs --arg m "共通の設定を入れる: $dest" '{message: $m, content: .}' |
        gh api -X PUT "repos/$full/contents/$dest" --input - --silent 2>/dev/null || ok=1
    done
    if [ "$ok" = 0 ]; then
      echo "   共通のワークフロー: 空のリポジトリに最初のコミットとして入れた($names)"
    else
      fail "   共通のワークフロー: 一部を入れられなかった($names)"
    fi
    return
  fi

  local pr
  # An error here must not read as "no PR": the branch is deleted below, which would close an
  # open PR, and declined() would then take its files as declined for good.
  if ! pr=$(gh pr list -R "$full" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null); then
    fail "   共通のワークフロー: 開いた PR を確かめられなかったので飛ばす"
    return
  fi
  if [ -n "$pr" ]; then
    echo "   共通のワークフロー: 足りない($names)。入れる PR #$pr がもうある"
    return
  fi

  # One commit with every missing file, on a fresh branch from the default branch.
  local base base_tree tree commit entries
  if ! base=$(gh api "repos/$full/git/ref/heads/$default" --jq .object.sha 2>/dev/null) ||
    ! base_tree=$(gh api "repos/$full/git/commits/$base" --jq .tree.sha 2>/dev/null); then
    fail "   共通のワークフロー: 既定ブランチを読めなかった"
    return
  fi
  entries=$(for t in "${files[@]}"; do
    render "$t" "$private" | jq -Rs --arg p "$(dest_of "$(basename "$t")")" '{path: $p, mode: "100644", type: "blob", content: .}'
  done | jq -s .)
  if ! tree=$(jq -n --arg b "$base_tree" --argjson e "$entries" '{base_tree: $b, tree: $e}' |
      gh api "repos/$full/git/trees" --input - --jq .sha 2>/dev/null) ||
    ! commit=$(jq -n --arg t "$tree" --arg p "$base" --arg m "共通のワークフローを入れる" '{message: $m, tree: $t, parents: [$p]}' |
      gh api "repos/$full/git/commits" --input - --jq .sha 2>/dev/null); then
    fail "   共通のワークフロー: コミットを作れなかった(トークンに Workflows の書き込みがあるか)"
    return
  fi
  gh api -X DELETE "repos/$full/git/refs/heads/$BRANCH" --silent 2>/dev/null
  if ! gh api "repos/$full/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$commit" --silent 2>/dev/null; then
    fail "   共通のワークフロー: ブランチを作れなかった"
    return
  fi
  local body dept_note=""
  for t in "${files[@]}"; do
    [ "$(basename "$t")" = dept.yml ] || continue
    dept_note="
- \`dept.yml\` は、依存の遅れのバッジとレポートを \`dept-badge\` ブランチに置きます。README には次の行を足します(非公開のリポジトリでも、読める人には表示されます)。

  \`\`\`markdown
  [![dept](https://github.com/$full/raw/dept-badge/dept.svg)](https://github.com/$full/blob/dept-badge/dept.md)
  \`\`\`"
  done
  body="shiroinock/workflows の \`templates/\` のうち、このリポジトリにまだ無いものを入れます(\`repo-baseline\` が出した PR です)。

$(for t in "${files[@]}"; do echo "- \`$(dest_of "$(basename "$t")")\`"; done)

- すでにあるファイルは書き換えていません。
- \`.github/workflows\` を変える PR なので、Claude のレビューは走りません。手で見てマージします。
- 入れたくないものは、このブランチで消し、そのファイル名(\`templates/\` での名前、例 \`claude-fix-ci.yml\`)を \`.github/baseline-skip\` に1行ずつ書いてからマージします。書かないと、次の見回りでまた入れる PR が出ます。
- この PR を閉じる(マージしない)と、ここにあるファイルはもう入れません。あとから共通に足されたテンプレートは、また PR で出ます。
- このリポジトリに共通の設定を一切入れたくないときは、トピック \`$SKIP_TOPIC\` を付けます。$dept_note"
  if pr=$(gh pr create -R "$full" --head "$BRANCH" --base "$default" \
      --title "共通のワークフローを入れる" --body "$body" 2>/dev/null); then
    echo "   共通のワークフロー: 入れる PR を出した($names): $(show_url "$pr")"
  else
    fail "   共通のワークフロー: PR を出せなかった"
  fi
}

secret_step() { # <full>
  local full=$1 value names
  if ! names=$(gh secret list -R "$full" --json name --jq '.[].name' 2>/dev/null); then
    fail "   シークレット: あるか確かめられなかった(トークンに Secrets の読み取りがあるか)"
    return
  fi
  if grep -qx CLAUDE_CODE_OAUTH_TOKEN <<<"$names"; then
    echo "   シークレット: CLAUDE_CODE_OAUTH_TOKEN はある"
    return
  fi
  if ! command -v op > /dev/null; then
    echo "   シークレット: CLAUDE_CODE_OAUTH_TOKEN が無い(op が無いので入れていない)"
    return
  fi
  if ! value=$(op read "$CLAUDE_TOKEN_OP_REF" 2>/dev/null) || [ -z "$value" ]; then
    echo "   シークレット: CLAUDE_CODE_OAUTH_TOKEN が無い(1Password から読めなかった: CLAUDE_TOKEN_OP_REF を確かめる)"
    return
  fi
  if printf '%s' "$value" | gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$full" > /dev/null 2>&1; then
    echo "   シークレット: CLAUDE_CODE_OAUTH_TOKEN を入れた"
  else
    fail "   シークレット: CLAUDE_CODE_OAUTH_TOKEN を入れられなかった"
  fi
  value=""
}

hide=false
show_url() { if [ "$hide" = true ]; then echo "(非公開)"; else echo "$1"; fi; }
detail() { if [ "$hide" = true ]; then echo "(非公開)"; else printf '%s' "$1" | tail -1; fi; }

for repo in "${repos[@]}"; do
  full="$OWNER/$repo"
  if ! info=$(gh api "repos/$full" --jq '{private, default_branch, archived, fork}' 2>/dev/null); then
    # Whether it is private is unknown here; in a public log, name nothing.
    if [ "${BASELINE_HIDE_PRIVATE:-}" = 1 ]; then printf '== (読めなかったリポジトリ)\n'; else printf '== %s\n' "$full"; fi
    fail "   読めなかった"
    continue
  fi
  private=$(jq -r .private <<<"$info")
  default=$(jq -r .default_branch <<<"$info")
  hide=false
  [ "${BASELINE_HIDE_PRIVATE:-}" = 1 ] && [ "$private" = true ] && hide=true
  if [ "$hide" = true ]; then printf '== (非公開のリポジトリ)\n'; else printf '== %s\n' "$full"; fi

  # Only 409 (Git Repository is empty) means empty; any other error skips the repository, so a
  # repository with commits never gets templates pushed straight to its default branch.
  probe "repos/$full/commits?per_page=1" 409
  case $? in
    0) empty=false ;;
    1) empty=true ;;
    *)
      fail "   中身があるか確かめられなかったので飛ばす"
      continue
      ;;
  esac

  workflows_step "$full" "$private" "$default" "$empty"
  secret_step "$full"

  if gh api -X PATCH "repos/$full" --silent \
      -F allow_merge_commit=true -F allow_squash_merge=false -F allow_rebase_merge=false \
      -F allow_auto_merge=true -F delete_branch_on_merge=true -F allow_update_branch=true 2>/dev/null; then
    echo "   マージ設定: OK"
  else
    fail "   マージ設定: 失敗"
  fi

  if gh api -X PATCH "repos/$full" --silent --input - 2>/dev/null <<'JSON'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
  then
    ss=$(gh api "repos/$full" --jq '.security_and_analysis.secret_scanning.status // "unavailable"')
    echo "   シークレットスキャン: $ss"
  else
    echo "   シークレットスキャン: このプランでは使えない"
  fi

  if gh api -X PUT "repos/$full/vulnerability-alerts" --silent 2>/dev/null; then
    gh api -X DELETE "repos/$full/automated-security-fixes" --silent 2>/dev/null
    echo "   Dependabot アラート: オン(自動の修正 PR はオフ)"
  else
    fail "   Dependabot アラート: 失敗"
  fi

  existing=$(gh api "repos/$full/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    echo "   ルールセット: 既にある(id $existing)ので触らない"
  elif out=$(gh api -X POST "repos/$full/rulesets" --input - <<<"$ruleset_body" 2>&1); then
    echo "   ルールセット: 作成"
  else
    fail "   ルールセット: 失敗 — $(detail "$out")"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "失敗が $failures 件あった(上を見る)"
  exit 1
fi
