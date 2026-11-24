# workflows

shiroinock のリポジトリで共通に使う GitHub Actions の再利用ワークフロー。中身はここだけで直し、各リポジトリは `templates/` の薄いファイルから呼ぶ。

| ワークフロー | すること |
|---|---|
| `claude.yml` | オーナーが issue・PR コメント・レビューで `@claude` と書くと Claude Code が動く。ほかの人のメンションでは動かない |
| `claude-review.yml` | 同じリポジトリのブランチから来た、下書きでない PR を Claude Code がレビューする。ボットの PR や push は `allowed_bots`(既定は Renovate と、CI の直しを push する Claude)に挙げたものだけ。直す指摘が無ければラベル「マージ予約」を付ける。検査 `review / verdict` は、指摘が残っている間は落ちる(必須の検査にする)。直さなくてもマージできるが直す価値のある小さい指摘は、マージを止めずに issue「あとで直す」へ PR ごとにまとめる(`collect_nits: false` で止める。呼ぶ側は `issues: write` を渡す) |
| `claude-fix-ci.yml` | PR の CI が落ちたら、Claude Code が原因を読んで枝を直し、push する(CI とレビューが走り直す)。人が直すべきもの、または決めた回数(既定 2 回)で直らないものは、PR で持ち主にメンションし、ラベル「人の手が要る」を付けて止まる。下書きとボットの PR には手を出さない(依存の更新のボットの PR は `claude-fix-deps.yml` が扱う)。すべてのワークフローの完了を受け、PR で落ちた実行だけを拾うので、CI の名前を合わせる必要は無い(CI が無ければ何もしない)。Claude のレビュー・アクションの固定・共通の静的ルールは飛ばす(静的ルールは手元の pre-push フックか `rules -- --fix` で直す)。ほかに飛ばしたいものは `skip_workflows` にファイル名を渡す |
| `claude-fix-deps.yml` | 依存の更新のボット(既定は Renovate)の PR が、Claude のレビューの指摘か CI の失敗で止まったら、Claude Code が枝を直して push し、CI とレビューに確かめさせる。ソースや設定を更新に合わせる、一緒に上げるべき依存を上げる、SDK が決める版を外れた依存を戻す、など手を動かすことだけをする。「この更新を見送るか」の判断と、直せないもの(ネイティブの道具で作るファイル、workflow や Renovate の設定の変更)は、選べる道を書いて持ち主にメンションし、ラベル「人の手が要る」を付けて止まる。決めた回数(既定 2 回)で進まないときも同じ。枝のパッケージのコードは動かさない(依存を入れない・テストもビルドも流さない。公開されて間もないパッケージの中身を Claude のトークンのそばで動かさないため)。lock ファイルは、レジストリの情報だけを読むコマンド(`pnpm install --lockfile-only --ignore-scripts` など)で作り直す。PR のコミットの最後の検査が終わったときに1度だけ動く |
| `merge-reservation.yml` | 「マージ予約」の付いた PR が既定ブランチに向いたら、自動マージ(マージコミット)を入れる。積み重ねた PR は、下の PR がマージされて付け替わるまで待つ |
| `dept.yml` | [dept](https://github.com/shiroinock/dept) で依存の遅れ(最新版までに出たリリースを major 30 / minor 3 / patch 1 で重み付けした合計)を数え、README に貼るバッジ `dept.svg`、どの依存がどれだけ遅れているかのレポート `dept.md`、結果 `dept.json` をブランチ `dept-badge` に置く。バッジは dept が自分で描き、外部のサービスは使わない。dept はリリースから取り、来歴の attestation を確かめてから使う。調べられなかった依存があれば、前のバッジを上書きせずに失敗する(`allow_errors: true` で置く)。main への push、毎週月曜、手動で走る。マージ予約(GITHUB_TOKEN)のマージは push を出さないので、`merge-reservation.yml` に `ci_workflow` を渡しているリポジトリでは、そのあと dispatch される CI が成功したときにも走る(CI の `name:` が `CI` であること)。`repo-baseline` は、ルートに `pnpm-lock.yaml` か `package-lock.json` があるリポジトリにだけ入れる(公開・非公開を問わない)。README には `[![dept](https://github.com/<owner>/<repo>/raw/dept-badge/dept.svg)](https://github.com/<owner>/<repo>/blob/dept-badge/dept.md)` と書き、クリックでレポートが開くようにする。`github.com/…/raw/…` の形なら、非公開のリポジトリでも読める人には表示される(`raw.githubusercontent.com` は非公開では表示されない) |
| `static-rules.yml` | 共通の静的ルール(`static-rules/` の ast-grep のルール)に引っかかるコードのある PR を落とす(`rules / rules`)。push はしない。手元で `nix run github:shiroinock/workflows#rules -- --fix` を流すと直せるものは直る。外したいルールは `.github/static-rules-off` に書く |
| `nix-hashes.yml` | flake の固定出力のハッシュ(`npmDepsHash`・`cargoHash`・`vendorHash`・pnpm の依存など)が、ロックファイルとずれている PR を落とす(`hashes / hashes`)。Renovate はロックファイルだけを上げて `flake.nix` のハッシュを直さないので、そのままマージすると `nix build` が壊れる。push はしない。手元で `nix run github:shiroinock/workflows#nix-hashes -- --fix <installable>` を流すと、`*.nix` の値を書き換える。`installables` には固定出力そのもの(例 `.#default.npmDeps`)を渡すと速い(既定 `.#default` はビルドまでする)。`flake.nix` のあるリポジトリにだけ、手で置く(テンプレートは無い)。呼ぶ側の例は下 |

### `nix-hashes.yml` の呼び方

`flake.nix` で `buildNpmPackage` などを使うリポジトリの `.github/workflows/nix-hashes.yml` に置き、`hashes / hashes` を必須の検査にする。

```yaml
name: Nix のハッシュ

on:
  # Every PR: a required check has to report on all of them.
  pull_request:

permissions: {}

jobs:
  hashes:
    uses: shiroinock/workflows/.github/workflows/nix-hashes.yml@<SHA>
    permissions:
      contents: read
    with:
      installables: .#default.npmDeps
      workflows_ref: <SHA> # the same SHA as the uses: line above
```

手元では、古い固定出力がストアに残っていると `nix build` がハッシュを確かめ直さず通ってしまう。`nix-hashes --fix` は、通ったあとに `--rebuild` で取り直して確かめる。

## 入れ方

ふつうは手で置かず、`repo-baseline` で入れる(次の節)。下は、手で入れるときの手順と、入れたあとに要るもの。

1. `templates/` のファイルを、呼ぶ側のリポジトリの `.github/workflows/` に置く。`dept.yml` は、ルートに `pnpm-lock.yaml` か `package-lock.json` があるリポジトリにだけ置く。
   - 非公開のリポジトリでは、`merge-reservation.yml` の `schedule` を消す(10分ごとの実行が Actions の無料枠を食うため)。
   - 既定ブランチの CI を、GITHUB_TOKEN のマージのあとで走らせ直したいときは、`ci_workflow` に CI のファイル名を渡す。その CI は `workflow_dispatch` を受け付けること。
   - リポジトリ固有のレビュー観点は `review_focus` に箇条書きで渡す。
   - 公開リポジトリなど、共通側の変更をすぐには受けたくないときは、`uses:` の `@main` を確かめたコミットの SHA に替える。`merge-reservation.yml` は `scripts/` を別に取ってくるので、`workflows_ref` にも同じ SHA を渡す(渡さないと main の `scripts/` が動く)。SHA で固定した参照は、共通の Renovate 設定を読んでいれば、main が進むたびに Renovate が PR で上げ、必須の検査が通れば Renovate が自動でマージする(Claude のレビューは workflow を変える PR では走らず、通った扱いになる)。
2. シークレット `CLAUDE_CODE_OAUTH_TOKEN` を登録する(`claude setup-token` で発行したもの)。
3. [Claude の GitHub App](https://github.com/apps/claude) をそのリポジトリに入れる。
4. アクションを SHA で固定する(`nix run github:shiroinock/workflows#pinact -- run`)。`templates/pinact.yml` を置くと、固定していないアクションのある PR を落とす(`pinact / pinact`)。固定した SHA は、共通の Renovate 設定(`helpers:pinGitHubActionDigests`)が上げ、あとから足したアクションも固定する。
5. 既定ブランチのルールセットで、CI のチェックを必須にする。必須のチェックが無いと、自動マージは CI の結果を待たずにすぐマージする。
   Claude のレビューの `review / verdict` も必須にする。指摘が残っている PR は、手でもマージできなくなる(workflow を変える PR は Claude がレビューできないので通り、人が見てマージする)。

## 新しいリポジトリに共通の設定を入れる

```bash
nix run github:shiroinock/workflows#repo-new -- <名前> --private --clone   # gh repo create のあと、共通の設定を入れる
nix run github:shiroinock/workflows#repo-baseline -- <名前> ...           # 既にあるリポジトリに入れる(名前なしで全部)
```

dotfiles では `repo-new`・`repo-baseline` という名前で入っている。`repo-baseline` は何度流してもよく、次を入れる。

- `templates/` のうち、まだ無いもの(Renovate の設定を含む。`dept.yml` は、ルートに `pnpm-lock.yaml` か `package-lock.json` があるリポジトリにだけ)。あるものは書き換えない。ただし、テンプレートの行に付けた zizmor の ignore のコメント(`@main` を追うこと、`pull_request_target` などの起動条件を使うことを、理由を書いて抑えるもの)は、すでにある写しの同じ行にも足す。足すのは同じ共通のジョブを呼ぶ写し(テンプレートの `uses: shiroinock/workflows/…@` の行があるもの。SHA で固定していてもよい)だけで、リポジトリが書き換えた行には触らない。空のリポジトリには最初のコミットとして入れ、中身のあるリポジトリには PR を出す(`.github/workflows` を変えるので、手で見てマージする)。その PR が開いたままなら、見回りのたびに今の既定ブランチの上で今のテンプレートに合わせて作り直す(中身が同じなら触らない。PR のブランチで写しを書き換えても戻る)。PR がテンプレートの置き場所のほかのファイル(`.github/baseline-skip` など)を変えていれば、人の手が入ったものとして触らない。非公開のリポジトリでは、`merge-reservation.yml` の schedule を外す。
  - 要らないテンプレートは、リポジトリの `.github/baseline-skip` に `templates/` でのファイル名を1行ずつ書く。入れる PR を閉じた(マージしなかった)ときも、その PR のファイルはもう入れない。
  - API のエラーは「無い」「空」とみなさず、その手順を飛ばす。失敗が1つでもあれば 1 で終わる。
- シークレット `CLAUDE_CODE_OAUTH_TOKEN`:無ければ 1Password から入れる(手元で `op` が使えるときだけ。参照は `CLAUDE_TOKEN_OP_REF` で替えられる)。
- マージの設定、シークレットスキャン、Dependabot のアラート、ルールセット「main を守る」。

`repo-new` を使わずに作ったリポジトリ(ブラウザ、素の `gh repo create`)は、週に1度の `baseline.yml` が拾って同じものを入れる。ここに足したテンプレートも、これで既存のリポジトリに配られる。トピック `no-baseline` を付けたリポジトリは触らない。動かすには、このリポジトリにシークレット `BASELINE_TOKEN`(オーナーの fine-grained token。すべてのリポジトリに Contents・Pull requests・Workflows・Administration の書き込みと、Secrets の読み取り)を入れる。ここからは `CLAUDE_CODE_OAUTH_TOKEN` を入れられないので、無いリポジトリはログに出るだけ。ログは公開なので、非公開のリポジトリと、読めなかったリポジトリの名前は出さない。

[Claude の GitHub App](https://github.com/apps/claude) は、「All repositories」で入れておくと、新しいリポジトリにも自動で入る。

## レビューの指摘を静的解析に回すサイクル

Claude のレビュー(PR ごとにトークンを使う)が繰り返し出す指摘のうち、静的解析で安く早く見つけられるものを、ルールにして CI と手元で見つけ・直すようにしていく。

1. **集めて選ぶ**(このリポジトリの `rule-harvest.yml`、毎週月曜):全リポジトリの Claude の行コメントと issue「あとで直す」の指摘を集め(トークンは使わない)、Claude(Sonnet)が1週分をまとめて1度だけ読んで、静的解析に回せるものを選ぶ。大半は動きの意味を追わないと分からない指摘なので落とす。残ったものは、置き場所(下の順番)と元になった指摘を付けて、issue「ルール候補」に書く。同じ形が次の週にも出たら、その issue に足す。
2. **人が選ぶ**:採用するものはルールにする PR を出し、見送るものは「Close as not planned」で閉じる(もう出さない)。
3. **ルールにする**:置き場所は `static-rules/README.md` の順番で決める。lint のルールではなく、ツールの設定・CI の1手・Renovate の設定で起きなくできるものはそこを変え(Renovate はここの `renovate/default.json`、CI はここの共通のワークフローに足す)、そのリポジトリがすでに回しているツールに組み込みのルールがあればそれを有効にし、型の情報が要るものは型を扱えるツールに任せ、どのツールにも無く構文の形だけで判定できるものだけを `static-rules/` に ast-grep で書く。`static-rules/` を変える PR では、`rules-impact.yml` が全リポジトリの既定ブランチに当てた件数を出す(誤検知を見るため)。
4. **見つけて直す**:CI の `static-rules.yml` が落とし、手元の `nix run github:shiroinock/workflows#rules -- --fix` が直す。CI からは push しない(GITHUB_TOKEN の push では次の検査が走らないため)。
5. **重ねない**:レビューのプロンプトは、CI の lint と共通の静的ルールで見つかるものを指摘しないように、また静的解析で拾えそうな指摘には目印を付けるようにしている。ツールの版上げで組み込みのルールが代わりになったら、ast-grep のルールを消す候補も出る。

`rule-harvest.yml` を動かすには、このリポジトリに次を入れる。

- シークレット `CLAUDE_CODE_OAUTH_TOKEN` と、[Claude の GitHub App](https://github.com/apps/claude)。
- シークレット `HARVEST_TOKEN`:非公開のリポジトリも読むための、オーナーの fine-grained token(すべてのリポジトリに Contents・Issues・Pull requests の読み取り)。無いと公開リポジトリだけを読む。`rules-impact.yml` も使う。

このリポジトリは公開なので、非公開のリポジトリの中身は外に出さない。集めたものはランナーの外に出さず(artifact にもログにも出さない)、issue には非公開のリポジトリの名前とリンクを伏せて書き、Claude にもそのコードや識別子を書かないように頼んでいる。

## 決まりごと

- Claude のジョブは読むこととコメントだけ。ラベルとマージは、Claude の構造化した判定だけを見る別のジョブが行う。
- レビューは push ごとに 2 つのジョブで終える(Claude が読む `review` と、書き込みをまとめて行う `verdict`)。非公開のリポジトリでは、数秒のジョブでも 1 ジョブ 1 分と数えて Actions の無料枠を使うため、ラベル・自動マージ・「あとで直す」・説明のコメントは `verdict` の手順にまとめている。前のレビューで付いたラベルも、レビューのあとで `verdict` が外す。レビューの間は、新しいコミットの必須の検査 `review / verdict` が保留なので、自動マージはそれを待つ。
- レビューの指摘は2つに分ける。直す必要のある指摘(`findings`)だけがマージを止める。直す価値はあるがマージは止めない小さい指摘(`nits`)は、ラベル「あとで直す」の issue に PR ごとに1つのコメントでまとめ、レビューし直すたびに最新の指摘に置き換える。作者は、ほかの指摘を直すついでに手軽なものを直してよいが、小さい指摘のためだけに push はしない(レビューが1周増えるため)。小さい指摘に入れるのは、全体から見て単純になる・そろう直しだけで、まれな端の場合のために特別扱いを足すだけの直しは入れない。一覧を片付けるときも、1件ずつではなく全体を見て、根の作りを直す。
- `.github/workflows` を変える PR は GITHUB_TOKEN ではマージできないので、手でマージする。
- ワークフローを変える PR では、Claude Code Action が既定ブランチと同じ内容か確かめるため、その PR のレビューは走らない。そのときはレビューの検査を通った扱いにし、理由を PR に1度だけコメントする。手で見てマージする。マージしたあとの PR から動く。
- 積み重ねた PR では向き先の枝の workflow が使われるので、向き先が古いままだと同じ理由でレビューが走らない。PR の差に workflow の変更が無いのにレビューが走らなかったときは、ジョブを失敗にして見えるようにしている。

## Claude の使用量

`claude.yml`・`claude-review.yml`・`claude-fix-ci.yml`・`claude-fix-deps.yml` は、Claude Code が使った量を artifact `claude-usage-<ジョブ>-<試行>` に残す(90 日)。サブスクのクオータのうち、Action がどれだけ食っているかを見る参考にする。

- Claude Code の OpenTelemetry の出力(OTLP の http/json)を、ランナーの中だけで受ける小さな口(Python の標準ライブラリ)に送らせ、受けたものをそのまま1行ずつ `otel.jsonl` に書く。外へは送らない。
- 入るもの:リクエストごとのモデル・入力と出力のトークン・キャッシュの読み書き・API 料金に換算した費用(`claude_code.api_request`)、トークンと費用のメトリクス、ツールの名前と成否。`meta.json` に、リポジトリ・workflow・ジョブ・実行・PR か issue の番号を書く。
- 入らないもの:プロンプト・応答・ツールの入力(Claude Code が伏せる)、アカウントの UUID。公開リポジトリの artifact は誰でも読めるので、伏せる設定(`OTEL_LOG_*`)は足さない。
- 費用は API 料金での換算で、サブスクのクオータの消費率そのものではない。クオータの消費率は手元の Claude Code のステータスラインにしか出ないので、時間帯を合わせて見比べる。
- Claude が走らなかったジョブ(ワークフローを変える PR のレビューなど)では残さない。`rule-harvest.yml` は、非公開のリポジトリの中身を読むのに公開のこのリポジトリで動くので、残さない。

## このリポジトリの Claude

ここにある共通の workflow を、このリポジトリ自身からも呼んでいる(`claude-code-review.yml`・`claude-mention.yml`・`merge-reservation-self.yml`。同じリポジトリの `./.github/workflows/…` を呼ぶので、PR の版の workflow が動く)。

- レビュー:`.github/workflows` を変える PR は Claude Code Action がレビューしないので、ここの PR の多くは通った扱いになり、手で見てマージする。`static-rules/`・`scripts/`・`templates/`・文書だけを変える PR はレビューされ、指摘が 0 件で「マージ予約」が付けば `merge-reservation-self.yml` が自動マージを入れる(`merge-reservation.yml` は共通の再利用 workflow なので、呼び出し側は別の名前にし、レビューには入力 `merge_reservation_workflow` でその名前を渡している)。GITHUB_TOKEN でのマージは push を出さないので、そのあと main の CI を workflow_dispatch で走らせる。
- `@claude`:issue「ルール候補」で `@claude` と書くと、ルールを足す PR を頼める。
- シークレット `CLAUDE_CODE_OAUTH_TOKEN` と Claude の GitHub App が要る(`rule-harvest.yml` と同じもの)。

## このリポジトリの検査

ここの変更は、`@main` で呼ぶすべてのリポジトリにすぐ届く。そのため PR ごとに CI(`lint`)で次を確かめ、必須のチェックにしている。道具と版は `flake.nix` と `flake.lock` で決まり、手元でも同じものが流れる。

- actionlint(`run:` の中は shellcheck):共通の workflow とテンプレートの文法・式・入力
- zizmor:権限の広げすぎ、信頼できない値の埋め込み、SHA で固定していないアクションなど、Actions のセキュリティ。`templates/` も見る(各リポジトリで zizmor を流しても指摘が出ないよう、わざとそうしている行には理由付きの `# zizmor: ignore[...]` を付ける)
- pinact:アクションをコミットの SHA で固定しているか(`pinact run` で固定し直せる)
- renovate-config-validator:共通の Renovate 設定とテンプレート
- `node --check` と shellcheck:`scripts/` のスクリプト
- `ast-grep test`:共通の静的ルールとそのテスト

```bash
nix flake check   # CI と同じ検査
nix run .         # 同じ検査を、作業中のファイルに対して流す
nix develop       # 道具の入ったシェル
```

固定したアクションの SHA と `flake.lock` は、このリポジトリの Renovate(共通の設定を読む)が上げる。
