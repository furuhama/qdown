# Qdown

Quiet Light テーマ専用の、無料・窓型 macOS Markdown ビューア。Swift + AppKit の
ドキュメントベースアプリで、本文は WKWebView に描画します。テーマ切替はなく、
`Qdown/Resources/quiet-light.css` をそのまま適用します。

## 動作環境

- macOS 13.0 以降
- Xcode（検証時: Xcode 26.3 / macOS 15.7.9 / Intel Mac）
- ユニバーサルバイナリ（arm64 + x86_64）

## ビルド

```sh
./scripts/build.sh
```

生成物:

```
build/Release/Qdown.app
```

`xcodebuild` を直接使う場合:

```sh
xcodebuild -project Qdown.xcodeproj -scheme Qdown -configuration Release \
  -derivedDataPath "$PWD/build/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

## 検証

```sh
./scripts/verify.sh
```

`build/Release/Qdown.app` をビルド済みの前提です。次の自動検証を行います。

- 実際の WKWebView / scheme handler / viewer.html / CSS / JS を使った描画テスト
- 見出し・表・タスクリスト・コードブロック・引用・画像・Mermaid の DOM 検証
- Quiet Light の計算済み色（背景 `#F0F0F7`、見出し `#705697`、Mermaid の
  `#EDEDF5` / `#705697` / `#333333`）の検証
- CSS Custom Highlight API と `<mark>` フォールバックの両方の検索検証
- 狭い窓（520px / 380px）と広い窓（1400px）での横スクロール・Mermaid はみ出し検証
- ネイティブウィンドウのスモークテスト（複数窓、サイドバー、検索件数、
  ズーム保存、サイドバークリック、相対 Markdown リンク）
- 外部画像・iframe・javascript: リンク・生 `<script>` の無効化検証
- `lipo -info` による arm64 + x86_64 の確認

結果は `build/test-output/` に JSON と PNG スナップショットで残ります。

## 主な操作

- `.md` / `.markdown` / `.txt` を Finder のダブルクリック、Open With、ドラッグ＆
  ドロップ、File > Open… で開く
- 左サイドバーの見出し（h1–h6）をクリックすると本文へスクロール
- ⌘F 検索、⌘G / ⇧⌘G で前後のマッチ、Esc で検索バーを閉じる
- ⌘+ / ⌘− で本文をズーム、⌘0 で等倍。倍率は `UserDefaults` に保存
- 相対パスの Markdown リンクは新しい Qdown の窓で開く。http(s) は既定のブラウザ
- アプリメニューの「Set Qdown as Default Markdown Viewer…」で `.md` の既定アプリに
  登録（実行するとシステムの既定アプリ設定が変わります）

## 構成

```
Qdown/
  Info.plist                 # ドキュメントタイプ、UTI、アプリ情報
  Sources/
    main.swift               # NSApplication 起動（storyboard なし）
    AppDelegate.swift        # メニュー、ファイルオープン、既定アプリ登録
    Document.swift           # NSDocument、文字コード判定
    DocumentWindowController.swift
    MarkdownWebView.swift    # WKWebView、JS ブリッジ、ドラッグ＆ドロップ
    LocalSchemeHandler.swift # qdown://app と qdown://doc、ネットワーク遮断
    SidebarViewController.swift
    FindBarView.swift        # 検索バーと本文ビュー
    LinkRouter.swift
    ZoomStore.swift
    RenderTestRunner.swift   # QDOWNTEST_MODE=render / smoke（検証用）
  Resources/
    quiet-light.css          # 正本。改変しない
    viewer.html / viewer.css / viewer.js
    vendor/                  # marked, highlight.js, mermaid（実行時ネットワークなし）
Tests/
  fixtures/                  # 相対リンク・画像・セキュリティ確認用
test.md                      # 見出し・表・タスク・コード・引用・Mermaid のサンプル
```

## テーマ CSS

`Qdown/Resources/quiet-light.css` はタスクシート添付の CSS とバイト単位で同一です。

```
SHA-256: 5e33b8e7a578e0b5f93467ff7882c4314d1fcad9d3863ea0656151f0300477b6
```

テーマ色の再導出はせず、CSS をそのまま読み込みます。`viewer.css` は検索ハイライト、
Mermaid の縮小、画像のはみ出し防止など、テーマがカバーしない挙動だけを追加します。

## Vendoring

`scripts/vendor.sh` で取得します（ビルド時のみネットワーク使用）。

| ライブラリ | バージョン | ライセンス |
| --- | --- | --- |
| marked | 12.0.2 | MIT |
| highlight.js (@highlightjs/cdn-assets) | 11.11.1 | BSD-3-Clause |
| mermaid | 10.9.5 | MIT |

ライセンス全文は `Qdown/Resources/vendor/` に同梱しています。

## 実行時ネットワーク

- ページは `qdown://app`（アプリ資産）と `qdown://doc`（文書ディレクトリ内の画像のみ）
  の専用 scheme だけで読み込みます
- CSP で `default-src 'none'`、`connect-src 'none'`、`img-src qdown: data:` とし、
  http(s) の script/style/img/frame を拒否します
- `WKContentRuleList` でも http(s)/ws(s)/ftp をブロックします
- `WKWebsiteDataStore.nonPersistent()` を使用します
- Markdown 内の外部画像は CSP でブロックされたうえで、DOM から `src` を除去して
  プレースホルダ表示にします

## 検証ハーネス

アプリのバイナリは**引数なし**で起動し、検証用の設定はすべて環境変数
（`QDOWNTEST_*`）で渡します。macOS の `NSDocumentController` は argv の
ファイル風引数を「開くべき書類」と解釈するため、無人検証で引数を渡すと
モーダルダイアログ待ちで停止することがあります。`scripts/verify.sh` は
全起動を `timeout` で包み、前後で `pkill -x Qdown` による掃除も行います。

```sh
# 描画テスト（実 WKWebView / 実 scheme handler）
QDOWNTEST_MODE=render \
QDOWNTEST_MARKDOWN=test.md \
QDOWNTEST_JSON=build/test-output/render.json \
QDOWNTEST_SNAPSHOT=build/test-output/top.png \
QDOWNTEST_SNAPSHOT_DIAGRAM=build/test-output/mermaid.png \
QDOWNTEST_SNAPSHOT_SECTION=build/test-output/section.png \
QDOWNTEST_FIND=Mermaid \
  build/Release/Qdown.app/Contents/MacOS/Qdown

# ネイティブウィンドウのスモークテスト
QDOWNTEST_MODE=smoke \
QDOWNTEST_FILES=$'test.md\nTests/fixtures/other.md' \
  build/Release/Qdown.app/Contents/MacOS/Qdown
```

主な環境変数:

| 変数 | 用途 |
| --- | --- |
| `QDOWNTEST_MODE` | `render` または `smoke` |
| `QDOWNTEST_MARKDOWN` | 描画する Markdown |
| `QDOWNTEST_JSON` | 結果 JSON の出力先 |
| `QDOWNTEST_SNAPSHOT` / `_DIAGRAM` / `_SECTION` | PNG スナップショット出力先 |
| `QDOWNTEST_FIND` / `QDOWNTEST_FALLBACK` | 検索語 / `<mark>` フォールバック |
| `QDOWNTEST_FILES` | スモークテストで開くファイル（改行区切り） |
| `QDOWNTEST_SIDEBAR_SNAPSHOT` | サイドバー PNG の出力先 |
| `QDOWNTEST_ZOOM_READ_ONLY` | `1` で UserDefaults のズーム値を書き換えずに読み取り検証 |
| `QDOWNTEST_LINK` | `1` で相対リンクの新規窓オープンを検証 |

後方互換のため `--render-test` / `--smoke-test` 形式も受け付けますが、
無人実行では使用しないでください。

## 既知の未確認・制約

- 人手による GUI 操作確認は行っていません。自動スナップショットと DOM メトリクスで
  確認した範囲は `report.md` を参照してください。
- Intel Mac 上でビルド・実行を確認しました。arm64 スライスは `lipo` で確認していますが、
  Apple Silicon 実機での起動は未確認です。
- 「Set Qdown as Default Markdown Viewer…」は実装済みですが、検証では実行していません
  （システムの既定アプリ設定を変更しないため）。
- ドラッグ＆ドロップは `WKWebView` の `NSDraggingDestination` で実装していますが、
  自動操作での検証はしていません。
- 相対 Markdown リンクで既に開いている文書を指した場合は、NSDocumentController の
  挙動により既存の窓を再利用することがあります。
- ファイル変更のライブリロード、編集、印刷/PDF、Quick Look などは対象外です。
