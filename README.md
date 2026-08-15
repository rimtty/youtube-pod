# YouTube Pod

iOS 27 / SwiftUI で動作する、技術検証用のオンデバイス音声ライブラリです。YouTube Data API から公開動画を探し、端末内に同梱した `yt-dlp` で M4A 音声を保存します。

> [!WARNING]
> このプロジェクトは開発署名による技術検証専用です。YouTube の規約および App Store Review Guideline 5.2.3 に適合する配布物ではありません。

## セットアップ

1. `cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig`
2. Google Cloud で YouTube Data API v3とOAuth同意画面を有効化し、iOS OAuth Client IDとReversed Client IDを設定
3. `./scripts/bootstrap.sh`
4. `open YouTubePod.xcodeproj`
5. Signing Team と Bundle ID を自分の環境に合わせ、iOS 27 実機で実行

Python 3.14、`yt-dlp 2026.07.04`、`yt-dlp-ejs 0.8.0`、`yt-dlp-apple-webkit-jsi 0.1.1` は `bootstrap.sh` が固定バージョンで準備します。JavaScriptチャレンジ用スクリプトもアプリへ同梱し、実行時のパッケージ取得・更新は行いません。

同梱CPythonのSimulator拡張はarm64向けです。Xcode 27をApple Silicon Macで使用してください。

YouTube Data APIへのすべてのリクエストは、アプリ内のGoogleログインで取得した`youtube.readonly` OAuthトークンを使用します。APIキーは使用しません。OAuth同意画面がテスト中の場合は、利用するGoogleアカウントをテストユーザーへ追加してください。

## 制限

- 公開済み動画のみ。Cookie、年齢制限、メンバー限定、非公開、ライブには非対応
- M4A 音声形式が提供される動画のみ。FFmpeg 変換は行わない
- ダウンロードはアプリがフォアグラウンドの間のみ
- YouTube の個人向けホーム推薦ではなく、登録チャンネル新着・人気動画・検索を表示

## 検証

通常の回帰テスト（外部の動画は取得しません）:

```sh
./scripts/verify.sh
```

オンデバイス抽出のネットワーク統合テスト（通常動画1本）:

```sh
YOUTUBEPOD_RUN_NETWORK_INTEGRATION=1 ./scripts/verify.sh
```

Shorts、30分以上、途中キャンセルも含める場合:

```sh
YOUTUBEPOD_RUN_NETWORK_INTEGRATION=1 \
YOUTUBEPOD_TEST_SHORTS_URL='https://www.youtube.com/shorts/VIDEO_ID' \
YOUTUBEPOD_TEST_LONG_URL='https://www.youtube.com/watch?v=VIDEO_ID' \
YOUTUBEPOD_TEST_CANCEL_URL='https://www.youtube.com/watch?v=VIDEO_ID' \
./scripts/verify.sh
```

統合テストは公開動画をM4Aとして一時保存し、動画トラックがなく音声トラックがあることをAVFoundationで検証してから削除します。キャンセルテストは一時ディレクトリが残らないことも検証します。実機の最終確認項目は [TESTING.md](TESTING.md) を参照してください。

音声抽出に一時的な通信・配信エラーが発生した場合は、yt-dlp内部の再試行に加えてアプリ側でも1秒、2秒、4秒の間隔で最大3回自動再試行します。未対応形式、非公開、年齢制限など恒久的な失敗は自動再試行せず、理由を表示します。
