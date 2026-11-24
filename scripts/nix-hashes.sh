# Nix の固定出力(npmDepsHash・cargoHash・vendorHash・pnpmDeps など)のハッシュが、ロックファイルと
# ずれていないかを確かめる。ずれていれば、正しい値と、それを書いた *.nix の場所を出して 1 で終わる。
# --fix を付けると、*.nix の古い値を正しい値に書き換え、ずれが無くなるまで繰り返す。
#
#   使い方: nix-hashes [--fix] [installable ...]   (既定 .#default)
#
# installable は固定出力そのもの(例 .#default.npmDeps、.#default.cargoDeps、.#default.goModules)を
# 渡すと速い。パッケージ全体(.#default)を渡すと、ハッシュのほかにビルドそのものも確かめる。
#
# 手元では、古い固定出力がストアに残っていると nix はハッシュを確かめ直さない。--fix のときは、
# 一度通ったあとに --rebuild でもう一度取ってきて確かめる(installable が固定出力のときに効く)。
# GitHub Actions(GITHUB_ACTIONS=true)では、ずれた行に注釈を付ける。


fix=false
if [ "${1:-}" = --fix ]; then
  fix=true
  shift
fi
[ "$#" -gt 0 ] || set -- .#default

log=$(mktemp)
trap 'rm -f "$log"' EXIT

annotate() { # <file> <line> <message>
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::error file=$1,line=$2::$3"
  else
    echo "$1:$2: $3"
  fi
}

# Builds the installables; prints "specified got" for each hash mismatch. Status: 0 built,
# 1 hash mismatches only, 2 another failure.
build() { # [nix build flags ...]
  local status
  nix build --no-link --keep-going --print-build-logs "$@" 2> >(tee "$log" >&2)
  status=$?
  wait
  [ "$status" = 0 ] && return 0
  # nix prints, for each mismatch:
  #   error: hash mismatch in fixed-output derivation '/nix/store/…-name.drv':
  #            specified: sha256-…
  #               got:    sha256-…
  sed -nE 's/^[[:space:]]*(specified|got):[[:space:]]*(sha256-[A-Za-z0-9+\/=]+).*$/\1 \2/p' "$log" |
    awk '$1 == "specified" { s = $2 } $1 == "got" && s != "" { print s, $2; s = "" }' |
    sort -u >"$log.pairs"
  if [ ! -s "$log.pairs" ]; then
    rm -f "$log.pairs"
    return 2
  fi
  cat "$log.pairs"
  rm -f "$log.pairs"
  return 1
}

# The tracked *.nix files that hold the hash, as "file:line".
places() { # <hash>
  git grep -n -F -e "$1" -- '*.nix' | cut -d: -f1,2
}

for round in 1 2 3 4 5 6 7 8 9 10; do
  pairs=$(build "$@")
  status=$?
  if [ "$status" = 0 ] && [ "$fix" = true ] && [ "$round" = 1 ]; then
    # Only the stale-store case is left: fetch again and compare.
    pairs=$(build --rebuild "$@")
    status=$?
    # --rebuild refuses what is not in the store yet, and finds nothing to compare in a
    # derivation that is not fixed-output; both are not a mismatch.
    [ "$status" = 2 ] && status=0
  fi
  if [ "$status" = 0 ]; then
    if [ "$round" = 1 ]; then
      echo "固定出力のハッシュはロックファイルと合っています。"
    else
      echo "ハッシュを直しました。差分を確かめてコミットしてください。"
    fi
    exit 0
  fi
  if [ "$status" = 2 ]; then
    echo "ハッシュのずれ以外で nix build が失敗しました(上のログ)。" >&2
    exit 2
  fi
  missing=false
  while read -r specified got; do
    where=$(places "$specified")
    if [ -z "$where" ]; then
      echo "$specified を書いた *.nix が見つかりません(正しい値は $got)。" >&2
      missing=true
      continue
    fi
    while IFS=: read -r file line; do
      if [ "$fix" = true ]; then
        echo "$file:$line: $specified → $got"
      else
        annotate "$file" "$line" "固定出力のハッシュがロックファイルとずれています。正しい値は $got です。nix run github:shiroinock/workflows#nix-hashes -- --fix $* で直せます。"
      fi
    done <<<"$where"
    if [ "$fix" = true ]; then
      cut -d: -f1 <<<"$where" | sort -u | while IFS= read -r file; do
        # Hashes are base64: / and + are literal here, | is not in the alphabet.
        sed -i.nix-hashes "s|$specified|$got|g" "$file" && rm -f "$file.nix-hashes"
      done
    fi
  done <<<"$pairs"
  if [ "$fix" = false ] || [ "$missing" = true ]; then
    exit 1
  fi
done
echo "10 回直しても、ずれが残りました。" >&2
exit 1
