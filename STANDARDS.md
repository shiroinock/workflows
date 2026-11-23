# ツールと版の標準

shiroinock のリポジトリで揃えるツールと版。新しく作るリポジトリはこれに従い、既存のものも少しずつ寄せる。

| 種類 | 標準 | 置き方 |
|---|---|---|
| Node | 24(LTS) | ルートに `.node-version`(中身は `24`)。CI は `actions/setup-node` の `node-version-file: .node-version`。ルートの `package.json` の `engines.node` は `>=24`。npm に公開するパッケージの `engines` は、利用者に約束する最低の版のままにする(上げるなら破壊的変更として扱う)。flake の開発シェルは `nodejs_24` |
| パッケージマネージャ | pnpm 10 | `package.json` の `packageManager` に `pnpm@10.x.y` を書く。ロックファイルは `pnpm-lock.yaml` だけ。CI は `pnpm/action-setup` で `packageManager` の版を使う。flake は `pnpm_10` |
| lint と整形 | Biome | `biome.json` を置き、ESLint と Prettier は使わない。レビューの指摘から足すルールの置き場所は `static-rules/README.md` の順番で決める |
| テスト(JS/TS) | Vitest | |
| TypeScript | 安定版の最新 | Renovate で上げる |
| Python | uv、3.13 | `pyproject.toml` の `requires-python` と `.python-version`。ロックファイルは `uv.lock`。lint と整形は Ruff、テストは pytest |
| 依存の更新 | Renovate | `templates/renovate.json` を置いて共通設定 `renovate/default.json` を読む。`dependabot.yml` は置かない |
| 脆弱性の報告 | Dependabot のアラート | `repo-baseline`(dotfiles)でオンにする。自動の修正 PR はオフにし、修正の PR は Renovate が出す |

## Renovate の共通設定

- 毎週月曜の朝に、minor と patch を1つの PR にまとめて出す。GitHub Actions は別の PR にまとめる。
- 脆弱性の修正は予定を待たずにすぐ出し、ラベル「セキュリティ」を付ける。
- Node と Python の大きな版上げは出さない。全リポジトリで揃えて、手で上げる。
- Renovate 自身は自動マージしない。PR は Claude のレビューを通り、指摘が無ければ「マージ予約」で自動マージされる。

## CI のコストとキャッシュ

非公開のリポジトリの Actions は月 3,000 分(GitHub Pro)で、Linux のジョブはジョブごとに分を切り上げて数える。数秒で終わるジョブも 1 分になるので、効くのはジョブの数を減らすこと、古い実行を止めること、重いもの(Docker・Nix)をキャッシュすること。npm や pnpm のインストールはもう数秒なので、そのキャッシュで稼げる分は小さい。

### ジョブを細かく分けない

- lint・型検査・テスト・ビルドのように数十秒で終わるものは、1 つのジョブの手順(step)にまとめる。
- ジョブを分けるのは、次のどちらかのときだけ。
  - 並べると全体が大きく速くなるとき(数分かかるものどうし)。
  - 権限を分けたいとき(書き込みの権限やシークレットを、一部の手順にだけ渡したい)。
- マトリクスも同じ。版や OS を並べる意味が薄ければ 1 つにする。

### 古い実行を止める

PR の CI には `concurrency` を付け、同じ PR に新しく push したら古い実行を取り消す。main への push は取り消さない(最後まで走らせてキャッシュや結果を残す)。

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

### キャッシュポイズニングの対策

PR のコードが書いたキャッシュを、あとで既定ブランチやリリースの実行が読むと、PR のコードを信頼する実行に持ち込める。だから書けるのは既定ブランチだけにする。

- **書くのは既定ブランチだけ**:キャッシュに書くのは、既定ブランチへの push・schedule・既定ブランチでの workflow_dispatch だけ。PR の実行は `actions/cache/restore` で読むだけにする。
  - PR で `actions/cache` を使わない(終わりに書いてしまう)。
  - setup-node・setup-python などの組み込みのキャッシュ(`cache:`)は、PR で書いてしまう。使わずに `actions/cache/restore` と `actions/cache/save` に分けるか、PR では切る。
- **キーは固定の値だけ**:キーはロックファイルのハッシュ(`hashFiles('pnpm-lock.yaml')` など)と OS(`runner.os`)などの固定の値で作る。ブランチ名・PR のタイトル・コミットメッセージなど、外から決められる値は入れない。
- **成果物はまっさらにビルドする**:リリース・デプロイ・npm などへの公開の成果物を作るジョブは、キャッシュを読まない。
- **権限の強い起動条件とは混ぜない**:`pull_request_target`・`workflow_run` などで動くジョブで、PR のコードとキャッシュを一緒に扱わない(PR のコードをチェックアウトしない、キャッシュを読み書きしない)。
- **Docker のレイヤー**:`docker/build-push-action` の `cache-from: type=gha` は読んでよい。`cache-to` は既定ブランチの実行だけに付け、PR では付けない。
- **Nix**:ビルドの結果を Actions のキャッシュで使い回すなら、同じく既定ブランチだけが書く。PR は読むだけにする。

読むだけと書くのを分ける形の例(pnpm の store):

```yaml
- id: store
  run: echo "path=$(pnpm store path --silent)" >> "$GITHUB_OUTPUT"
- uses: actions/cache/restore@<SHA> # v4
  with:
    path: ${{ steps.store.outputs.path }}
    key: pnpm-${{ runner.os }}-${{ hashFiles('pnpm-lock.yaml') }}
- run: pnpm install --frozen-lockfile
# ……lint・型検査・テスト・ビルド……
- if: github.event_name != 'pull_request' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)
  uses: actions/cache/save@<SHA> # v4
  with:
    path: ${{ steps.store.outputs.path }}
    key: pnpm-${{ runner.os }}-${{ hashFiles('pnpm-lock.yaml') }}
```

Docker の例:

```yaml
- uses: docker/build-push-action@<SHA> # v6
  with:
    cache-from: type=gha
    cache-to: ${{ github.event_name != 'pull_request' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch) && 'type=gha,mode=max' || '' }}
```

### 確かめ方

- `zizmor` を流し、`cache-poisoning` の指摘が出ないこと(このリポジトリなら `nix run .`、ほかのリポジトリなら `nix run nixpkgs#zizmor -- .github/workflows`)。
- zizmor が見るのは主に、リリースや公開のワークフローでキャッシュを使っていないか。PR で書いていないか・キーに外の値が入っていないかは、上の決まりで目で確かめる。
