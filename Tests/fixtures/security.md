# セキュリティ確認用フィクスチャ

生 HTML のスクリプト、外部画像、iframe、javascript: リンクが無効化されることを確認します。

<script>window.__qdownPwned = 1;</script>

<img src="https://example.com/remote.png" alt="remote image">

<iframe src="https://example.com/"></iframe>

[危険なリンク](javascript:window.__qdownPwned=2)

## ローカル画像

![ローカル画像](test-image.png)

## 通常のテキスト

この段落は普通に表示される必要があります。
