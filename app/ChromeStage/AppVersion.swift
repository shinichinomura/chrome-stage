import Foundation

// 実行中のビルドを識別するための情報。
// バージョン番号(MARKETING_VERSION)は滅多に変えないため、どのコミットのビルドが動いているかを
// 区別できるよう、ビルド時に Run Script フェーズ「Embed Git Info」が Info.plist に書き込む
// git のコミット・コミット数(= CFBundleVersion)・ビルド日時を併記する。
//
// 起動時に一度だけ読んで保持する。/Applications の .app を差し替えても、動作中のプロセスは
// 差し替え前のバンドルから起動したものなので、その時点の値を表示し続ける必要がある
struct AppVersion {
    static let current = AppVersion(bundle: .main)

    let version: String    // CFBundleShortVersionString(例: 0.1.0)
    let build: String      // CFBundleVersion(コミット数)
    let gitCommit: String  // 短縮ハッシュ。未コミットの変更を含むビルドは -dirty が付く
    let buildDate: String  // ビルド日時
    let bundlePath: String // 起動元の .app のパス

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        gitCommit = info["ChromeStageGitCommit"] as? String ?? "unknown"
        buildDate = info["ChromeStageBuildDate"] as? String ?? "unknown"
        bundlePath = bundle.bundlePath
    }

    // 1 行表記(メニュー・ログ用)。例: 0.1.0 (build 22, 48d2b8b)
    var summary: String {
        "\(version) (build \(build), \(gitCommit))"
    }

    // 詳細(バージョンダイアログ・--version 用)
    var details: String {
        """
        バージョン: \(version) (build \(build))
        コミット: \(gitCommit)
        ビルド日時: \(buildDate)
        起動元: \(bundlePath)
        """
    }
}
