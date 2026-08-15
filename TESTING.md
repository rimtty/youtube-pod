# YouTube Pod 検証チェックリスト

## 自動テスト

- URL解析、表示フォーマット、DTO変換、重複排除
- OAuth未認証、401、403、オフライン、登録チャンネルのページング
- 直列ダウンロードキュー、待機項目と実行中項目の個別キャンセル
- M4Aの検証、SwiftDataへの保存、視聴回数更新、ファイル削除
- 明示実行時のみ、公開動画を使った同梱Python／yt-dlpのネットワーク統合テスト

## 現在の自動検証結果（2026-08-16）

- Xcode 27.0 / Apple Swift 6.4 / iOS 27.0 Simulator
- Debug全テスト: 124件（うちネットワーク実動画4件は通常実行ではスキップ）、失敗0件
- 通常公開動画、Shorts、30分超の公開動画: M4A取得、音声トラックあり、動画トラックなしを確認
- 長尺取得の途中キャンセル、追加リトライ、起動時の残存一時フォルダ清掃を確認
- `yt-dlp-ejs 0.8.0`を固定同梱し、実行時ダウンロードなしでWebKit JavaScriptチャレンジ処理を確認
- Release / generic iOS Simulator: ビルド成功
- iPhone 16 Pro Max向け開発署名ビルド: ビルド・インストール・起動成功
- Googleの復元済みセッションに`youtube.readonly`が含まれることを、APIトークン発行前にも検証
- 認証を復元できない場合も、保存済み音声だけを開けるローカルライブラリ導線を実装
- 実機データコンテナから保存済みM4A 10件を読み取り検査し、全件AAC音声のみ・動画トラック0を確認
- 上記10件には`#shorts`を含む短尺項目と60分超の長尺項目が含まれ、抽出用`YouTubePod-*`一時フォルダの残存なし
- 登録チャンネル新着は最初の20チャンネルだけを取得し、後続ページはユーザー操作時だけ取得
- ホームと登録チャンネル画面の同時取得をsingle-flightで共有し、最初のページの`playlistItems.list`が合計20回を超えないことを確認
- 手動更新は対象フィードだけを更新し、別フィードの15分キャッシュを破棄しないことを確認
- Pull to Refreshは成功後60秒間のクールダウン中に再通信せず、完了後の連打でクォータを消費しないことを確認
- 異なる登録チャンネルページを同時取得しても`playlistItems.list`のアプリ全体並列数が4以下であることを確認
- 51件の視聴回数更新が`videos.list`の50件＋1件へ分割され、429と500を別のUIエラーへ分類することを確認
- 15分キャッシュの期限境界、全件キャンセルの抽出中／再試行待ち／取込中、取込失敗後のキュー継続を確認
- 保存済み音声の削除後にダウンロード完了表示を破棄し、キュー末尾操作でも再生履歴を0秒で上書きしないことを確認
- 起動時に中断された隠しステージングM4Aも孤児ファイルとして清掃することを確認
- watchOS 27 / Apple Watch Series 9（41mm／45mm）Simulator: Watchアプリのビルドと回帰テストに成功
- Watch側回帰テスト: 73件、失敗0件（転送protocol、受信、SwiftData、ACK outbox、削除、ローカルプレイヤーを含む）
- Watch転送envelope／ACK／inventory／削除commandのencode/decode、schema不一致、破損payload、不正値、再生位置clampを確認
- WCSession callback URLを同期退避し、payload＋sidecar完成後のatomic rename、rename直前終了からの復旧、破損receiptの隔離を確認
- 音声trackあり／動画trackなし／M4A／宣言サイズをAVFoundationで検証し、容量不足を構造化エラーへ分類
- Watch SwiftDataへの取込はreceiptをcommit完了まで保持し、保存失敗・プロセス終了窓でも旧音声と再試行payloadを失わないことを確認
- stale revision、同revision別transfer、削除tombstone、音声／画像の到着順、音声前画像の削除を確認
- ACK outboxの再起動復元、送信失敗後の再試行、不正ACK行の隔離、実ファイル欠落時にinventoryへ掲載しないことを確認
- 削除commandをdelegate callback内で同期永続化し、再起動後に音声より先に適用して遅延配送による復活を防ぐことを確認
- Watchのローカルプレイヤーは再生／一時停止、15秒送り／戻し、シーク、前後項目、再生完了、削除時の停止とキュー除外を確認
- 0.5秒の進捗監視、5秒単位と停止時の再生位置保存、保存失敗後の再試行、連続シーク時の古い通知抑制を確認
- 音声ファイル欠落、AVPlayerItem失敗、音声セッション中断、出力経路切断、Now Playingとリモート操作の状態遷移を確認
- Watchライブラリは16:9サムネイル、再生位置、受信中／同期失敗／再試行、再生不可状態、Dynamic Type、VoiceOver、Reduce Transparencyに対応
- iPhone側Watch転送は、直列キュー、重複抑止、進捗、キャンセル、最大2回の自動再試行、stale ACK拒否、送信完了とWatch ACKの順序入替、再起動時照合をスタブで確認
- 新しい転送／Watch ACKによる古い自動再試行の無効化、Watch取込確認タイムアウト、タイムアウト後の遅延ACK受理を確認
- 自動再試行のsnapshot clone中に遅延ACKが届いても、確認済みrevisionを上書きしないことを確認
- WCSession再activation時に送信完了callbackを失っても、後続の直列キューが停止しないことを確認
- 転送元削除後も独立スナップショットを維持し、atomic clone、孤立snapshot／中断staging cleanup、先頭snapshot欠落後のキュー継続を確認
- 既存の未versioned `SavedAudio`ストアから複合Schemaを開き、全メタデータ保持と再オープンを確認。段階移行は実ストアで`unknown model version`となるため採用せず、データ削除fallbackも行わない
- iPhoneはWatchの`applicationContext`在庫を起動時と更新時に受信し、library instance／generation／時刻／transfer ID／revision／ファイルサイズを照合することを確認
- 同generationの競合在庫、古いWatch instance、重複項目、サイズ不一致を拒否し、欠落項目を即削除せず再照合待ちにすることを確認
- Watch削除要求をSwiftDataへ先に永続化してから送信し、再activation時の再送、重複要求、遅延import ACKによる削除状態の復活防止を確認
- inventory不一致後は、iPhoneの元音声から新しいsnapshot／revisionを作る再転送で復旧し、元音声がない場合は再転送を案内しない
- iPhoneライブラリの44pt Watch転送操作、進捗／キャンセル／再試行／削除、独立したWatch管理タブ、Google未ログイン時のライブラリ＋Watch導線を実装
- iPhone／Watch各バンドルへRequired Reason APIのPrivacy Manifestを同梱し、Disk Space、UserDefaults、File Timestampの宣言を自動検証
- CIでiOS static analyzerとApple Watch Series 9（41mm／45mm）の両サイズを検証

`./scripts/verify.sh` はiOS通常回帰テスト（実動画4件はスキップ）、`./scripts/verify_watch.sh`はwatchOS 27のApple Watch Series 9（41mm／45mm）Simulatorを必要に応じて作成し、両サイズで回帰テストを実行する。各スクリプトはビルド成果物内のPrivacy Manifestも検証する。`YOUTUBEPOD_RUN_NETWORK_INTEGRATION=1 ./scripts/verify.sh` は通常動画の実取得も実行する。Shorts・30分超・キャンセルのURL指定方法はREADMEを参照する。

## Apple Watch実機の合格条件（Simulatorでは検証不可）

以下はペアリング済みApple Watch Series 9以降とiPhoneの実機で確認する。今回のSimulator実装中は未完了タスクとして維持する。

- [ ] 短いM4Aをバックグラウンド転送し、Watchで取込ACK後に「保存済み」になる
- [ ] 通常動画、Shorts、30分以上のM4Aを各1本転送できる
- [ ] iPhone／Watchアプリが前面にない状態でも配送が完了または再開する
- [ ] 転送中キャンセル後に一時ファイルが残らず、再試行できる
- [ ] Watch再起動後も一覧、サムネイル、再生位置が復元する
- [ ] iPhoneが機内モードでもWatchのローカル音声を再生できる
- [ ] Bluetoothヘッドホンで画面消灯後も再生と操作が継続する
- [ ] 41mm／45mmでライブラリとフルプレイヤーが崩れず、最大Dynamic Type、VoiceOver、Reduce Transparencyで操作できる
- [ ] Digital Crownでシークしても連続seekや進捗表示のぶれが発生しない
- [ ] WatchのAppIconがランチャーの円形マスク内で自然に表示される
- [ ] Watchの容量不足時に既存ライブラリが壊れない
- [ ] Watchから削除後に音声、画像、SwiftDataがすべて消える
- [ ] iPhoneの元音声を削除してもWatch側コピーを再生できる
- [ ] iPhoneのWatchタブで件数、空き容量、最終同期時刻が実機Watchの状態と一致する
- [ ] Watchへの転送、キャンセル、再試行、Watchから削除がiPhoneの管理タブへ正しく反映される
- [ ] Google未ログイン／iPhone機内モードでも、iPhoneのWatch管理タブとWatchのローカル再生を利用できる

## iOS 27実機の合格条件

以下は開発署名した同一ビルドで確認する。

- [ ] Googleログイン後にホーム、検索、登録チャンネルが表示される
- [x] 通常の公開動画をM4Aとして保存できる
- [x] 公開ShortsをM4Aとして保存できる
- [x] 30分以上の公開動画をM4Aとして保存できる
- [x] 3ファイルすべてに音声トラックがあり、動画トラックがない
- [x] 取得中のキャンセル後に再試行でき、一時ファイルが残らない
- [x] 機内モードとアプリ再起動後も一覧、サムネイル、再生位置が復元する
- [ ] ロック画面でも再生が続き、再生・一時停止・15秒送り／戻しを操作できる
- [ ] 削除後に音声、サムネイル、SwiftDataの項目がすべて消える

## YouTube Data API実通信の再検証（延期）

- [ ] 2026-08-16時点ではGoogle Cloudプロジェクトの日次10,000クォータへ到達しているため、実APIのリクエスト数検証を延期
- 再開条件: 日次クォータがリセットされ、Google Cloud Consoleでメソッド別リクエスト数を確認できること
- 検証前に時刻と`playlistItems.list`の開始カウントを記録し、同じビルドで1回だけアプリを起動する
- ホームの読込完了後に登録チャンネルタブへ1回切り替える。Pull to Refreshと「さらに読み込む」は押さない
- 合格条件: 初回ページの`subscriptions.list`は1回、`channels.list`は1回、`playlistItems.list`は最大20回、`videos.list`は登録新着で最大2回。人気動画を含む総リクエストは最大25回
- Homeと登録チャンネルの同一ページ要求がsingle-flightで共有され、`playlistItems.list`が40回へ倍増しないこと
- 60秒以内にPull to Refreshを繰り返しても追加リクエストが発生しないこと
- メトリクス反映には遅延があり得るため、開始・終了時刻を固定して同じ時間範囲を比較する

## 実機テスト時に必要な手動操作

1. iPhoneをロック解除し、Macを信頼する。
2. 必要な場合は「設定 > プライバシーとセキュリティ > デベロッパモード」を有効にする。
3. 初回起動時に開発元を信頼し、Googleログインを完了する。
4. バックグラウンド再生確認時に端末をロックし、ロック画面の操作を行う。

## オフライン復元の確認手順

1. オンライン中に音声を1件以上保存し、途中まで再生してアプリを終了する。
2. 機内モードを有効にしてアプリを再起動する。
3. Google認証を復元できない場合は「保存済みの音声を開く」を押す。
4. 一覧、ローカルサムネイル、前回の再生位置が表示されることを確認する。
5. 再生、一時停止、シーク、前後項目、削除が通信なしで動くことを確認する。
6. ローカルライブラリではホーム、検索、登録チャンネル、視聴回数更新が表示されないことを確認する。

## UI・アクセシビリティ確認

- [ ] 文字サイズを最大にしてもログイン、一覧、ミニプレイヤー、フルプレイヤーの操作が欠けない
- [ ] VoiceOverで動画行、保存ボタン、再生状態、再生位置、プレイヤー操作を区別して読み上げる
- [ ] ライト／ダークモードで文字とカードのコントラストが保たれる
- [ ] 「透明度を下げる」で認証画面、カード、ミニ／フルプレイヤーが不透明な背景になる
- [ ] 「視差効果を減らす」で認証波形と画面遷移が過剰に動かない
- [ ] 下方向スクロールで縮小したタブバーが、上方向スクロールで再表示される
- [ ] ミニプレイヤーのサムネイル、再生ボタン、シークバーがタブバーと重ならず収まる
- [ ] 70%表示のフルプレイヤーでタイトル、サムネイル、シーク、5操作ボタンが利用できる

エラーまたはクラッシュが発生した場合は、その画面を閉じずに発生時刻と操作を記録する。キャンセル確認後は、アプリデータコンテナの`tmp`に`YouTubePod-*`が残っていないことも確認する。
