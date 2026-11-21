# ツールと版の標準

shiroinock のリポジトリで揃えるツールと版。新しく作るリポジトリはこれに従い、既存のものも少しずつ寄せる。

| 種類 | 標準 | 置き方 |
|---|---|---|
| Node | 24(LTS) | ルートに `.node-version`(中身は `24`)。CI は `actions/setup-node` の `node-version-file: .node-version`。ルートの `package.json` の `engines.node` は `>=24`。npm に公開するパッケージの `engines` は、利用者に約束する最低の版のままにする(上げるなら破壊的変更として扱う)。flake の開発シェルは `nodejs_24` |
| パッケージマネージャ | pnpm 10 | `package.json` の `packageManager` に `pnpm@10.x.y` を書く。ロックファイルは `pnpm-lock.yaml` だけ。CI は `pnpm/action-setup` で `packageManager` の版を使う。flake は `pnpm_10` |
| lint と整形 | Biome | `biome.json` を置き、ESLint と Prettier は使わない |
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
