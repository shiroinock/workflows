# 新しいリポジトリを作り、共通の設定(repo-baseline)を入れる。
#   使い方: repo-new <名前> [gh repo create の引数...]   例: repo-new my-tool --public --clone
# gh repo create をそのまま呼び、成功したら、いま作ったリポジトリに repo-baseline を流す。
# どのリポジトリを作ったかは引数からではなく、直前に作られた自分のリポジトリを API で引いて決める
# (対話式や --template で作っても同じに動く)。
OWNER="${OWNER:-shiroinock}"

since=$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)
gh repo create "$@" || exit $?

name=$(gh api "user/repos?affiliation=owner&sort=created&direction=desc&per_page=10" |
  jq -r --arg o "$OWNER" --arg s "$since" \
    '[.[] | select(.owner.login == $o and .created_at >= $s)][0].name // empty')
if [ -z "$name" ]; then
  echo "repo-new: いま作った $OWNER のリポジトリが見つからない(ほかのオーナーに作った?)。必要なら repo-baseline <名前> を流す" >&2
  exit 1
fi

echo "repo-new: $OWNER/$name に共通の設定を入れる"
repo-baseline "$name"

if [ -d "$name/.git" ] && [ -z "$(git -C "$name" rev-parse --verify -q HEAD)" ]; then
  echo "repo-new: 手元の clone($name)はまだ空なので、共通の設定のコミットを取り込む:git -C $name pull origin $(gh repo view "$OWNER/$name" --json defaultBranchRef --jq .defaultBranchRef.name)"
fi
