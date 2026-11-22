# workflows

shiroinock のリポジトリで共通に使う GitHub Actions の再利用ワークフロー。中身はここだけで直し、各リポジトリは `templates/` の薄いファイルから呼ぶ。

| ワークフロー | すること |
|---|---|
| `claude.yml` | オーナーが issue・PR コメント・レビューで `@claude` と書くと Claude Code が動く。ほかの人のメンションでは動かない |
| `claude-review.yml` | 同じリポジトリのブランチから来た、下書きでない PR を Claude Code がレビューする。ボットの PR や push は `allowed_bots`(既定は Renovate と、CI の直しを push する Claude)に挙げたものだけ。直す指摘が無ければラベル「マージ予約」を付ける。検査 `review / verdict` は、指摘が残っている間は落ちる(必須の検査にする)。直さなくてもマージできるが直す価値のある小さい指摘は、マージを止めずに issue「あとで直す」へ PR ごとにまとめる(`collect_nits: false` で止める。呼ぶ側は `issues: write` を渡す) |
| `claude-fix-ci.yml` | PR の CI が落ちたら、Claude Code が原因を読んで枝を直し、push する(CI とレビューが走り直す)。人が直すべきもの、または決めた回数(既定 2 回)で直らないものは、PR で持ち主にメンションし、ラベル「人の手が要る」を付けて止まる。下書きとボットの PR には手を出さない |
| `merge-reservation.yml` | 「マージ予約」の付いた PR が既定ブランチに向いたら、自動マージ(マージコミット)を入れる。積み重ねた PR は、下の PR がマージされて付け替わるまで待つ |

## 入れ方

1. `templates/` のファイルを、呼ぶ側のリポジトリの `.github/workflows/` に置く。
   - 非公開のリポジトリでは、`merge-reservation.yml` の `schedule` を消す(10分ごとの実行が Actions の無料枠を食うため)。
   - 既定ブランチの CI を、GITHUB_TOKEN のマージのあとで走らせ直したいときは、`ci_workflow` に CI のファイル名を渡す。その CI は `workflow_dispatch` を受け付けること。
   - リポジトリ固有のレビュー観点は `review_focus` に箇条書きで渡す。
   - 公開リポジトリなど、共通側の変更をすぐには受けたくないときは、`uses:` の `@main` を確かめたコミットの SHA に替える。`merge-reservation.yml` は `scripts/` を別に取ってくるので、`workflows_ref` にも同じ SHA を渡す(渡さないと main の `scripts/` が動く)。SHA で固定した参照は、共通の Renovate 設定を読んでいれば、main が進むたびに Renovate が PR で上げ、必須の検査が通れば Renovate が自動でマージする(Claude のレビューは workflow を変える PR では走らず、通った扱いになる)。
2. シークレット `CLAUDE_CODE_OAUTH_TOKEN` を登録する(`claude setup-token` で発行したもの)。
3. [Claude の GitHub App](https://github.com/apps/claude) をそのリポジトリに入れる。
4. アクションを SHA で固定する(`nix run github:shiroinock/workflows#pinact -- run`)。`templates/pinact.yml` を置くと、固定していないアクションのある PR を落とす(`pinact / pinact`)。固定した SHA は、共通の Renovate 設定(`helpers:pinGitHubActionDigests`)が上げ、あとから足したアクションも固定する。
5. 既定ブランチのルールセットで、CI のチェックを必須にする。必須のチェックが無いと、自動マージは CI の結果を待たずにすぐマージする。
   Claude のレビューの `review / verdict` も必須にする。指摘が残っている PR は、手でもマージできなくなる(workflow を変える PR は Claude がレビューできないので通り、人が見てマージする)。

## 決まりごと

- Claude のジョブは読むこととコメントだけ。ラベルとマージは、Claude の構造化した判定だけを見る別のジョブが行う。
- レビューの指摘は2つに分ける。直す必要のある指摘(`findings`)だけがマージを止める。直す価値はあるがマージは止めない小さい指摘(`nits`)は、ラベル「あとで直す」の issue に PR ごとに1つのコメントでまとめ、レビューし直すたびに最新の指摘に置き換える。作者は、ほかの指摘を直すついでに手軽なものを直してよいが、小さい指摘のためだけに push はしない(レビューが1周増えるため)。小さい指摘に入れるのは、全体から見て単純になる・そろう直しだけで、まれな端の場合のために特別扱いを足すだけの直しは入れない。一覧を片付けるときも、1件ずつではなく全体を見て、根の作りを直す。
- `.github/workflows` を変える PR は GITHUB_TOKEN ではマージできないので、手でマージする。
- ワークフローを変える PR では、Claude Code Action が既定ブランチと同じ内容か確かめるため、その PR のレビューは走らない。そのときはレビューの検査を通った扱いにし、理由を PR に1度だけコメントする。手で見てマージする。マージしたあとの PR から動く。
- 積み重ねた PR では向き先の枝の workflow が使われるので、向き先が古いままだと同じ理由でレビューが走らない。PR の差に workflow の変更が無いのにレビューが走らなかったときは、ジョブを失敗にして見えるようにしている。

## このリポジトリの検査

ここの変更は、`@main` で呼ぶすべてのリポジトリにすぐ届く。そのため PR ごとに CI(`lint`)で次を確かめ、必須のチェックにしている。道具と版は `flake.nix` と `flake.lock` で決まり、手元でも同じものが流れる。

- actionlint(`run:` の中は shellcheck):共通の workflow とテンプレートの文法・式・入力
- zizmor:権限の広げすぎ、信頼できない値の埋め込み、SHA で固定していないアクションなど、Actions のセキュリティ
- pinact:アクションをコミットの SHA で固定しているか(`pinact run` で固定し直せる)
- renovate-config-validator:共通の Renovate 設定とテンプレート
- `node --check`:`scripts/` のスクリプト

```bash
nix flake check   # CI と同じ検査
nix run .         # 同じ検査を、作業中のファイルに対して流す
nix develop       # 道具の入ったシェル
```

固定したアクションの SHA と `flake.lock` は、このリポジトリの Renovate(共通の設定を読む)が上げる。
