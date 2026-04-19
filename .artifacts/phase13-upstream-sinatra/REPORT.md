# Phase 13 — Modern Sinatra (upstream v4.2.1) + pinpoint Opal patches

- ブランチ: `feature/phase13-upstream-sinatra` (based on phase12.5)
- ROADMAP 対応: Phase 13 "Modern Sinatra migration (janbiedermann fork 離脱)"
- ステータス: 実装 + 378 smoke + /test/{crypto,sequel,scheduled} 全緑 + dogfooding 済

## 成果

| 項目 | Before (phase12.5) | After (Phase 13) |
|---|---|---|
| Sinatra バージョン | 4.0.0（janbiedermann/homurabi inline-patched fork）| **4.2.1（upstream pristine）** |
| Opal 特化パッチの所在 | `vendor/sinatra/base.rb` inline diff（~24 hunks、メソッド本体に混在） | `lib/sinatra_opal_patches.rb` 単一ファイル（13 項目、class reopen で override） |
| Sinatra upstream との bit-identical | ❌ 乖離 | ✅ `diff -r vendor/sinatra_upstream /tmp/sinatra-4.2.1/lib/sinatra` は `images/` 以外ゼロ |
| npm test | 378 tests | **378 tests, 0 failed** |
| `/test/crypto` (Workers self-test) | 26/26 | **26/26** |
| `/test/sequel` | 8/8 | **8/8** |

## ディレクトリ構成

```
vendor/
├─ sinatra/                # thin wrappers (5 files, each < 10 lines)
│   ├─ base.rb             # require upstream + require patches
│   ├─ main.rb             # require upstream
│   ├─ indifferent_hash.rb # require upstream
│   ├─ show_exceptions.rb  # require upstream
│   └─ version.rb          # require upstream
├─ sinatra_upstream/       # PRISTINE sinatra/sinatra v4.2.1 — bit-identical to GitHub tag
│   ├─ base.rb (2173 lines)
│   ├─ indifferent_hash.rb
│   ├─ main.rb
│   ├─ middleware/
│   │   └─ logger.rb
│   ├─ show_exceptions.rb
│   └─ version.rb
├─ ipaddr.rb               # stub — Opal doesn't bundle IPAddr stdlib
├─ rackup.rb               # stub — Sinatra's `begin; require 'rackup'; rescue LoadError; end`
│                          #   pattern trips Opal's compile-time resolver
└─ rubygems/version.rb     # stub Gem::Version.new comparator for `Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0")`
lib/
└─ sinatra_opal_patches.rb  # 13 overrides against upstream v4.2.1
```

## lib/sinatra_opal_patches.rb に集約した 13 項目

各項目は `class ReopenedClass; ... end` スタイルで上流を塗り替え。header コメントに上流の行番号を明記。

| # | override 対象 | 上流挙動 | Opal/Workers 対応 |
|---|---|---|---|
| 1 | `Sinatra::Request#forwarded?` (base.rb:66) | `!forwarded_authority.nil?` — Rack 3.1 helper 依存 | `@env.include?('HTTP_X_FORWARDED_HOST')` で生ヘッダ判定 |
| 2 | `Sinatra::Response#calculate_content_length?` (base.rb:208) | 常に true for Array body | body 内に JS Promise（async route 返値）が混じってたら false（bytesize 計算不能） |
| 3 | `Sinatra::Helpers#body=` (base.rb:300) | `Rack::Files::BaseIterator` 比較 | `Rack::Files::Iterator`（公開クラス）へ差し替え |
| 4 | `Sinatra::Helpers#uri` (base.rb:330) | `host << "http://"` 等 String mutation | Opal String は immutable なので `+=` に |
| 5 | `Sinatra::Helpers#content_type` (base.rb:400) | `mime_type << ';'; mime_type << params` | 同じく `+=` ＋ `', '` セパレータ（Rack 慣用） |
| 6 | `Sinatra::Helpers#etag_matches?` (base.rb:722) | `split(',').map(&:strip)` | regex split で単一 pass |
| 7 | `Sinatra::Base#static!` (base.rb:1147) | `URI_INSTANCE.unescape` + `static_headers` | `::CGI.unescape` ＋ static_headers 無効（R2/CDN で直接配信するため Ruby 側で設定不要） |
| 8 | `Sinatra::Base#invoke` (base.rb:1167) | Integer/String/Array/each の4分岐 | 第5分岐として JS Promise（`::Cloudflare.js_promise?(res)`）を追加。`res.respond_to?(:then)` は Ruby 2.6+ の Kernel#then と衝突するので使えない |
| 9 | `Sinatra::Base.new!` (base.rb:1676) | `alias new! new` on singleton class | Opal の alias-into-`class << self` が正しく解決されないため `allocate + initialize` で明示 |
| 10 | `Sinatra::Base.setup_default_middleware` (base.rb:1821) | `ExtendedRack + ShowExceptions + MethodOverride + Head + logging + sessions + protection + host_authorization` | host_authorization を外す（IPAddr 依存・CF Workers 側で host 許可制御） |
| 11 | `Sinatra::Base.setup_null_logger` / `setup_custom_logger` (base.rb:1846/1854) | `Sinatra::Middleware::Logger` 使用 | homurabi は Sinatra::Middleware::Logger を vendor しないので `Rack::NullLogger` / `Rack::Logger` へ |
| 12 | `Sinatra::Base.force_encoding` (base.rb:1942) | `.force_encoding(enc).encode!` | Opal の `String#encode!` は NotImplementedError なので `.encode!` を削除 |
| 13 | `Sinatra::Delegator.delegate` (base.rb:2113) | `super if respond_to? method_name` | Opal の `super` inside `define_method` が hard-wired に 'delegate' を指すので super probe を削除 |

加えて class-body 末尾で 2 箇所 settings を中和:

- `Sinatra::Base.set :host_authorization, {}` — default IPAddr オブジェクトを空 Hash に
- `Sinatra::Base.set :static_headers, false` — `static!` で使わない旨をソース設定側にも反映

## 外部依存スタブ

| ファイル | 目的 |
|---|---|
| `vendor/rackup.rb` | 空ファイル。Sinatra の `begin; require 'rackup'; rescue LoadError; end` を Opal のコンパイル時 require resolver が静的に追うので、LoadError rescue が効かず必要 |
| `vendor/ipaddr.rb` | 最小 IPAddr.new(_) スタブ。upstream が `host_authorization` default の permitted_hosts で IPAddr を生成する（homurabi では override して空 hash にしているので実行時未使用だが、class-body 評価で触れる） |
| `vendor/rubygems/version.rb` | Gem::Version.new(str) と `<=>` の整数配列比較。IndifferentHash の `except` override ガードで使われる |

これら 3 ファイルを `lib/opal_patches.rb` 冒頭で pre-require することで、upstream Sinatra のロード時に未定義 const エラーが出ないようにしている。

## ファイル変更サマリ

```
22 files changed
lib/opal_patches.rb             (+17 lines)   rubygems/version + opal-parser pre-require
lib/sinatra_opal_patches.rb     (NEW, 287 lines)  13 overrides
vendor/ipaddr.rb                (NEW, 17 lines)   IPAddr stub
vendor/rackup.rb                (NEW, 11 lines)   rackup stub
vendor/rubygems/version.rb      (NEW, 27 lines)   Gem::Version stub
vendor/sinatra.rb               (+3 lines)    entry preloads
vendor/sinatra/*.rb             (rewritten as 5 thin wrappers: base/main/indifferent_hash/show_exceptions/version, 5-12 lines each)
vendor/sinatra_upstream/*.rb    (NEW, bit-identical pristine 4.2.1: base.rb 2173 lines + 4 others + middleware/logger.rb)
.artifacts/phase13-upstream-sinatra/
  REPORT.md (THIS FILE)
  dogfooding.txt
  upstream-bit-identical.txt
```

## Workers 実機ドッグフーディング

`HOMURABI_ENABLE_CRYPTO_DEMOS=1 wrangler dev` で以下をすべて検証:

- `GET /` → 200 OK (ERB layout + chat nav)
- `GET /d1/users` → 4 rows from D1
- `GET /demo/sequel` → 4 rows via Sequel D1 adapter
- `POST /api/login` → JWT HS256 token
- `GET /api/me` (Bearer) → payload / claims 正しく展開
- `PUT /kv/foo` / `GET /kv/foo` → KV round-trip
- `GET /test/crypto` → **26/26 pass** (RSA / ECDSA / Ed25519 / AES-GCM/CBC/CTR / JWT all-algo)
- `GET /test/sequel` → **8/8 pass**

## Before vs After（ファイル単位）

### vendor/sinatra/base.rb
- Before: 2188 lines (homurabi-inline-patched 4.0.0)
- After: 10 lines (require wrapper)

### vendor/sinatra_upstream/base.rb
- Before: N/A
- After: 2173 lines (bit-identical to sinatra/sinatra@v4.2.1)

### lib/sinatra_opal_patches.rb
- Before: N/A
- After: 287 lines (全 override が集約)

## 次回 Sinatra 上流 bump 手順

```
$ curl -sL https://github.com/sinatra/sinatra/archive/refs/tags/vX.Y.Z.tar.gz | tar xz
$ cp -r sinatra-X.Y.Z/lib/sinatra/*.rb  vendor/sinatra_upstream/
$ cp -r sinatra-X.Y.Z/lib/sinatra/middleware  vendor/sinatra_upstream/
$ npm test                            # 378 tests 全緑なら ok
$ npm run build && npx wrangler dev   # dogfooding
```

unify-patched ブランチがなくなったため、diff の見通しは劇的に改善。
Phase 12.5 と合わせて homurabi は **「上流 gem を vendor、homurabi 側パッチは
単一ファイル」方針の教科書例** になった。
