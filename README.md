# workflows

shiroinock のリポジトリで共通に使う GitHub Actions の再利用ワークフロー。中身はここだけで直し、各リポジトリは `templates/` の薄いファイルから呼ぶ。

| ワークフロー | すること |
|---|---|
| `claude.yml` | オーナーが issue・PR コメント・レビューで `@claude` と書くと Claude Code が動く。ほかの人のメンションでは動かない |
| `claude-review.yml` | 同じリポジトリのブランチから来た、下書きでない PR を Claude Code がレビューする。ボットの PR は `allowed_bots`(既定は Renovate)に挙げたものだけ。直す指摘が無ければラベル「マージ予約」を付ける |
| `merge-reservation.yml` | 「マージ予約」の付いた PR が既定ブランチに向いたら、自動マージ(マージコミット)を入れる。積み重ねた PR は、下の PR がマージされて付け替わるまで待つ |

## 入れ方

1. `templates/` の3ファイルを、呼ぶ側のリポジトリの `.github/workflows/` に置く。
   - 非公開のリポジトリでは、`merge-reservation.yml` の `schedule` を消す(10分ごとの実行が Actions の無料枠を食うため)。
   - 既定ブランチの CI を、GITHUB_TOKEN のマージのあとで走らせ直したいときは、`ci_workflow` に CI のファイル名を渡す。その CI は `workflow_dispatch` を受け付けること。
   - リポジトリ固有のレビュー観点は `review_focus` に箇条書きで渡す。
   - 公開リポジトリなど、共通側の変更をすぐには受けたくないときは、`uses:` の `@main` を確かめたコミットの SHA に替える。`merge-reservation.yml` は `scripts/` を別に取ってくるので、`workflows_ref` にも同じ SHA を渡す(渡さないと main の `scripts/` が動く)。SHA で固定した参照は、共通の Renovate 設定を読んでいれば、main が進むたびに Renovate が PR「共通の workflow」で上げる。workflow を変える PR なので手でマージする。
2. シークレット `CLAUDE_CODE_OAUTH_TOKEN` を登録する(`claude setup-token` で発行したもの)。
3. [Claude の GitHub App](https://github.com/apps/claude) をそのリポジトリに入れる。
4. 既定ブランチのルールセットで、CI のチェックを必須にする。必須のチェックが無いと、自動マージは CI の結果を待たずにすぐマージする。

## 決まりごと

- Claude のジョブは読むこととコメントだけ。ラベルとマージは、Claude の構造化した判定だけを見る別のジョブが行う。
- `.github/workflows` を変える PR は GITHUB_TOKEN ではマージできないので、手でマージする。
- ワークフローを変える PR では、Claude Code Action が既定ブランチと同じ内容か確かめるため、その PR のレビューは失敗する。マージしたあとの PR から動く。積み重ねた PR では向き先の枝の workflow が使われるので、向き先が古いままだと同じ理由でレビューが走らない。レビューが走らなかったときは、ジョブを失敗にして見えるようにしている。
