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

Python 3.14、`yt-dlp 2026.08.19`、`yt-dlp-ejs 0.8.0`、`yt-dlp-apple-webkit-jsi 0.1.1` は `PythonRuntime/requirements.lock` の固定バージョンを使って `bootstrap.sh` が準備します。JavaScriptチャレンジ用スクリプトもアプリへ同梱し、実行時のパッケージ取得・更新は行いません。 `yt-dlp-ejs` と `yt-dlp-apple-webkit-jsi` には `scripts/patch_python_runtime.py` でローカルパッチを適用します（`bootstrap.sh` が自動実行）。内容は、隠しWKWebView内のチャレンジ解決がYouTubeアプリへのUniversal Link遷移を起こす不具合の回避で、上流の [yt-dlp/ejs#76](https://github.com/yt-dlp/ejs/issues/76) と [grqz/yt-dlp-apple-webkit-jsi#5](https://github.com/grqz/yt-dlp-apple-webkit-jsi/issues/5) が解決されるまでの暫定対応です。詳細は `PythonRuntime/patches/README.md` を参照してください。yt-dlpのキャッシュはアプリの `Library/Caches/yt-dlp` に置き、ダウンロード間で共有します。

同梱CPythonのSimulator拡張はarm64向けです。Xcode 27をApple Silicon Macで使用してください。

YouTube Data APIへのすべてのリクエストは、アプリ内のGoogleログインで取得した`youtube.readonly` OAuthトークンを使用します。APIキーは使用しません。OAuth同意画面がテスト中の場合は、利用するGoogleアカウントをテストユーザーへ追加してください。

Google認証を復元できない場合でも、認証画面の「保存済みの音声を開く」からローカルライブラリだけを利用できます。このモードではホーム、検索、登録チャンネル、視聴回数更新、新規ダウンロードは表示せず、端末内の一覧・サムネイル・再生位置・音声だけを使用します。

## YouTube Data APIの通信予算

登録チャンネル新着は、初回に最大20チャンネルだけを取得します。各チャンネルのUploadsプレイリストはYouTube Data APIの仕様上個別に問い合わせる必要があるため、初回ページの`playlistItems.list`は最大20回です。次の20チャンネルは、登録チャンネル画面で「さらに登録チャンネルを読み込む」を押した場合だけ取得します。

同じGoogleセッション・同じページの同時リクエストは1本へ集約し、ホームと登録チャンネル画面が同時に表示されても重複取得しません。成功結果は15分キャッシュし、Pull to Refreshは表示中のフィードだけを更新します。動画検索はキーボードの検索確定時だけ実行し、新しい検索を開始した場合は古い検索をキャンセルします。

Pull to Refreshの成功後60秒間は同じページを再通信せず、直前の結果を表示します。異なるページやチャンネル画面から同時に取得しても、`playlistItems.list`の並列通信はアプリ全体で最大4本です。現在の実APIリクエスト数検証はGoogle Cloudプロジェクトの日次クォータ到達により延期しています。再検証条件と期待リクエスト数は[TESTING.md](TESTING.md)に記録しています。

## 制限

- 公開済み動画のみ。Cookie、年齢制限、メンバー限定、非公開、ライブには非対応
- M4A 音声形式が提供される動画のみ。FFmpeg 変換は行わない（保存後にコンテナだけをフラット MP4 へ書き直す。AAC の再エンコードはしない）
- ダウンロードはアプリがフォアグラウンドの間のみ
- YouTube の個人向けホーム推薦ではなく、登録チャンネル新着・人気動画・検索を表示
- Googleログイン済みでもYouTube本体の視聴履歴はData APIから取得不可（`watchHistoryNotAccessible`）

## 検証

通常の回帰テスト（外部の動画は取得しません）:

```sh
./scripts/verify.sh
```

Apple Watch Series 9以降 / watchOS 26.0以降が対象です。回帰テストはwatchOS 27 Simulatorで実行します（Series 9を優先）:

```sh
./scripts/verify_watch.sh
```

WatchConnectivityの実ファイル配送とバックグラウンド再生の最終確認には、ペアリング済みiPhone／Apple Watch実機が必要です。未完了の実機項目は[TESTING.md](TESTING.md)に残しています。

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
