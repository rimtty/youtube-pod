# 同梱Pythonパッケージへのローカルパッチ

`PythonRuntime/site-packages` は `scripts/bootstrap.sh` が `requirements.lock` から再インストールするため、git管理外です。上流にまだ取り込まれていない修正は `scripts/patch_python_runtime.py` が適用します。パッチの正本はそのスクリプトで、この README は背景の説明です。

- `bootstrap.sh` がインストール直後に自動実行します（冪等）。
- `scripts/verify.sh` は `--check` で適用済みかを検証し、`scripts/test_webkit_jsi_patch.py` でホストのWebKitに対する回帰テストを実行します。
- 上流バージョンが変わるとスクリプトは失敗します。`requirements.lock` を上げる際はアンカーを再検証し、上流で修正済みならパッチを削除してください。

## 背景の不具合

「音声を保存」を実行すると、yt-dlpのJavaScriptチャレンジ解決のために `yt-dlp-apple-webkit-jsi` が非表示のWKWebViewを作り、そこで `yt-dlp-ejs` のソルバーを実行します。ソルバーの環境初期化は `globalThis.location = new URL("https://www.youtube.com/watch?v=yt-dlp-wins")` を無条件に代入しますが、実ブラウザでは `window.location` への代入は実ナビゲーションです。WebKitはAPI経由で実行したJavaScriptをユーザー操作扱いにするため、youtube.comへの遷移がUniversal Linkとして処理され、iOSがYouTubeアプリを起動していました（存在しない動画IDなので「この動画は再生できません」と表示される）。

- 上流報告: [yt-dlp/ejs#76](https://github.com/yt-dlp/ejs/issues/76)、[grqz/yt-dlp-apple-webkit-jsi#5](https://github.com/grqz/yt-dlp-apple-webkit-jsi/issues/5)

## パッチ1: yt-dlp-apple-webkit-jsi 0.1.1（`yt_dlp_plugins/webkit_jsi/lib/api.py`）

navigation delegateに `webView:decidePolicyForNavigationAction:decisionHandler:` を追加し、プラグイン自身の `navigate_to`（`loadHTMLString:baseURL:`）以外のナビゲーションをすべてcancelします。スクリプト起因の遷移がプロセス外へ出ないための防御層です。cancel時は `Cancelled navigation to <url>` をdebugログへ出します。

## パッチ2: yt-dlp-ejs 0.8.0（`yt_dlp_ejs/yt/solver/core.min.js` と yt-dlp同梱の `vendor/yt.solver.core.js`）

`location` の代入を `typeof globalThis.location === "undefined"` で保護し、ブラウザ環境ではナビゲーション自体を発生させません。yt-dlpはソルバースクリプトをSHA3-512で検証するため、`yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py` の `yt.solver.core.js` と `yt.solver.core.min.js` のハッシュをパッチ後のファイルから再計算して書き換えます（書き換えた印としてヘッダ直後にコメントを追加）。

## 削除手順

上流が修正版を公開したら、`requirements.lock` を更新し、該当パッチを `scripts/patch_python_runtime.py` から外してください。両方とも不要になったら `bootstrap.sh` と `verify.sh` からスクリプト呼び出しを削除します。
