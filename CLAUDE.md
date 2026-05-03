これは個人用のプロジェクトです。このリポジトリ以外にPRを送ることを完全に禁止します。

## PR / merge / push 権限

このリポジトリ内であれば、Claude は PR を自分で作成・更新してよい (`gh pr create` / `gh pr edit`)。承認は自分でやらない (マスターがマージする) が、「PR作成自体はマスター承認待ち」の運用は**しない** — 作業の節目で素直に PR を立てて、本文に変更点・検証結果・リスクを書く。push (`git push origin <branch>` / tag push) も同じく自走で良い (リリースフローはあくまで `.github/workflows/release-gems.yml` 経由の tag push、後述)。

逆に **絶対やらない** こと:
- main ブランチへの直接 push
- 動作確認が終わっていない状態での push
- 既存 PR / 既存 commit / 既存 tag への force push (新しい version / 新しい branch を切る)
- 他人のレビュー / 承認を取り消す変更


設計方針として、Ruby の「驚き最小の法則」を重視する。既存の Ruby / Sinatra / Rack の慣習で自然に書ける形を第一にし、互換性のない制約や独自流儀は極力露出させない。やむを得ず制約がある場合も、利用側に特殊な書き方を強いる前に互換レイヤーや実装側の吸収を検討し、どうしても露出が必要な差分だけを明示する。

`__await__` / `# await:` などの Opal / Workers 非同期変換の内部表現は、表面 API・README・docs・examples・template にできる限り露出させない。ユーザーが書く Ruby は同期的な Ruby / Sinatra / Rack の形を保ち、必要な非同期境界は gem / build pipeline / runtime 側で吸収する。内部実装やテストで必要な場合でも、公開 example にコピーされる説明・コードには出さない。

v1 未満では互換性維持を優先しない。理想のインターフェイスに届いていない既存 surface は、Ruby / Sinatra / Rack の驚き最小に反する限り、alias や互換レイヤーで延命せず破壊的に置き換える。特に CLI は「古い名前も残す」より「最終形に一本化する」を優先する。

## リネーム / 撲滅作業は常に「全部やる」

「ブランド一新したい」「古い名前を消したい」系のタスクで、Claude が「最小スコープ案」「段階移行案」「一部だけ案」を出すのを **恒久的に禁止**。マスターは毎回「全部やる以外にないです。毎回これ以外の選択肢なし」と返してくる前提で動くこと。

具体的に意味するのは:

- 古い名前 / モジュール / file path / CLI bin / モジュール参照を、リポジトリ全域 (`gems/*`, `examples/*`, `test/*`, `app/*`, scaffolder template, README, CHANGELOG, ドキュメント、コメント) で例外なく置き換える。
- 後方互換 alias (`OLD = NEW` の constant 定義 / `require` 互換 shim / 古い CLI 名の wrapper など) は **作らない**。v1 未満の破壊的変更ルールに従って bump する (`0.x.y` → `0.(x+1).0` 程度)。
- 「これは外向きAPIなので残しておく」みたいな保守的な判断は不要。homura は個人プロジェクトで、外部利用者の互換性を理由に古い名前を保護する意味はない。
- Codex 等のレビューが「これは keep でいい」と言ってきても、マスター指示が優先。Codex 推奨はあくまで参考。
- 終わったら必ず `npm test` / 各 example の `homura build` + `wrangler dev` curl まで通す。一部 rename し残しがあると Opal compile か runtime のどちらかで爆発するので、**作業途中で中断しない**。

## gem 配布ルール

`examples/*/Gemfile` を含むあらゆる「動かすことを目的とする」 Gemfile では、**未リリースの gem を `path:` でつなぐのは恒久的に禁止**。新作 gem は RubyGems に公開してから `gem 'foo', '= x.y.z'` のように version 指定で参照すること。

- 検証目的で一時的に `path:` を使うのは可。ただし作業完了前に必ず公開版へ切り替える。
- 既にリリース済みの gem を monorepo dev 用途で `path:` するパターン（homura-runtime / sinatra-homura / sequel-d1 が今までそうしてきた）も同じ理由で避ける。`bundle update <gem>` でリリース版に追従できる構成を基本とする。
- gem に変更を加えたら、利用側の検証を path: で済ませた直後に **gemspec の version を bump → tag push でリリース → 利用側 Gemfile の version 指定を更新** までを 1 連の作業として完結させる。「path: のまま放置」は不可。
- リリースしないと検証できないものはまずリリース。リリースに躊躇するくらいなら設計から見直す。

### gem リリース手順 (重要: 手元で `gem push` しない)

このリポジトリの gem は **`.github/workflows/release-gems.yml` が GitHub Actions + RubyGems Trusted Publishing でリリース** する。手元の `gem push` は使わない（credentials を持つ必要が無く、リリース履歴は git tag で追える設計）。

手順:

1. 該当 gem の `gemspec` / `version.rb` を bump し、`CHANGELOG.md` を書き、PR をマージする。
2. `git tag <gem-name>-v<version>` を打つ (例: `sinatra-inertia-v0.1.0`, `homura-runtime-v0.2.24`)。
3. `git push origin <tag>` で tag を push すると release-gems.yml が走り、`gem build` → `gem push` まで自動実行される。

新作 gem を追加するときは:

1. `.github/workflows/release-gems.yml` の `on.push.tags` に `<gem-name>-v*` を、`Resolve gem target` ステップの case 文に新しい分岐を追加する（`expected_version` 抽出ロジックも込み）。
2. **初回だけ** RubyGems の web UI でその gem 名に対する Trusted Publisher (GitHub repository = `kazuph/homura`, environment = `release`) を登録する。これをやらないと初回 push が認証エラーで落ちる。
3. その後は tag push 1 発でリリースできる。

絶対にやってはいけないこと:

- `gem signin` してローカルから `gem push` する。リリース履歴と署名が一元化されない。
- gemspec の version を bump せずに tag を打つ（workflow が `expected_version` 不一致で abort する設計だが、手元のキャッシュが汚れる）。
- tag を後から付け替える / 同じ tag で force push する（push 済み gem は yank しか出来ないため、必ず新しい version を切る）。
