# Chrome Stage の使い方

Chrome のプロファイルごとのウィンドウを、一つの作業領域で切り替える macOS 用ツールです。Google Chrome 本体のウィンドウをそのまま使用します。

## 動作環境

- macOS 26（Tahoe）以降
- Apple Silicon または Intel Mac
- Google Chrome

## インストールと初回設定

1. GitHub の [Releases](https://github.com/shinichinomura/chrome-stage/releases) から配布 ZIP をダウンロードして展開します。
2. `ChromeStage.app` を「アプリケーション」フォルダに移動して開きます。
3. 「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で Chrome Stage を許可します。Chrome ウィンドウの位置・サイズ・前面化を操作するために使います。
4. Chrome Stage は Dock に表示されません。画面上部のメニューバーにある重なった四角のアイコンを開きます。
5. Chrome で管理したいウィンドウを手前に出し、メニューの「最前面の Chrome ウィンドウを Slot に追加…」を選んで名前を付けます。
6. 別のウィンドウも同様に登録します。パレットの名前をクリックすると切り替わります。

画面収録の許可は不要です。Google Chrome へのログインや Chrome プロファイルの作成は Chrome 側で行ってください。

## 主な操作

| 操作 | ショートカット |
| --- | --- |
| 次の Slot | Control + Option + Tab |
| 前の Slot | Control + Option + Shift + Tab |
| Slot 1〜9 | Control + Option + 1〜9 |
| 全ウィンドウを画面内へ戻す | Control + Option + U |

パレットの項目をドラッグすると順序を変えられます。左端のハンドルでパレット自体を移動できます。

## ウィンドウを戻す・終了する

メニューの「Unpark All Chrome Windows」で退避したウィンドウを画面内に戻せます。「Chrome Stage を終了」でも復帰します。異常終了後にウィンドウが見えなくなった場合は、Chrome Stage を再起動して「Unpark All Chrome Windows」を実行してください。

通常の Chrome ウィンドウを同じ Space 内で使用してください。フルスクリーン、別 Space 間の操作、DevTools やポップアップの管理は対象外です。

## 更新・アンインストール

更新時は、メニューから Chrome Stage を終了してから「アプリケーション」内のアプリを新しいものに置き換えます。自動更新機能はありません。登録した Slot は保持されます。

アンインストール時も、先にメニューから終了してウィンドウを復帰させてください。その後アプリを削除します。設定も消す場合は `~/Library/Application Support/ChromeStage/` を削除します。

## サポート

不具合や質問は [GitHub Issues](https://github.com/shinichinomura/chrome-stage/issues) へお願いします。macOS・Chrome のバージョン、メニューのバージョン表示、再現手順を添えてください。Issue は公開されるため、顧客名・閲覧内容・セッションファイルなどの機密情報は記載しないでください。

Chrome Stage は Google の公式製品ではありません。
