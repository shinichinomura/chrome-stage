import AppKit
import CryptoKit
import Security

// 自動更新(更新チェック → ダウンロード → 検証 → 置き換えて再起動)。
//
// 外部依存ゼロの方針(Sparkle は使わない)に合わせ、GitHub Releases の公開 API だけで実装する。
// 配布物は公開リポジトリの Releases にある `ChromeStage-<version>.zip` と `.zip.sha256`。
//
// セキュリティ方針:
// - 通信は GitHub への HTTPS のみ。送るのは「最新リリースの問い合わせ」で、User-Agent にはアプリ名とバージョンだけを入れる
//   (Slot 名・ウィンドウ情報・URL などは一切送らない)
// - 真正性は SHA-256 ではなくコード署名で担保する。ダウンロードした .app が
//   「このアプリの Developer ID Application 署名(同じ Team ID)」かつ公証済み(Gatekeeper 承認)で、
//   リリースのバージョンと一致し、実行中より新しい場合だけ採用する(SHA-256 は転送の破損検出)
// - ダウンロードしたファイルは実行せず、置き換えスクリプトはアプリ自身が固定の内容を書き出す
final class UpdateService {
    static let shared = UpdateService()

    static let repository = "shinichinomura/chrome-stage"
    static let bundleIdentifier = "com.shinichinomura.ChromeStage"
    static let teamIdentifier = "2B4YHY8VXE"

    // 検証済みでインストール待ちの更新
    struct Prepared {
        let version: String
        let appURL: URL
    }

    enum State {
        case idle
        case checking
        case downloading(version: String)
        case ready(Prepared)
        case failed(String)
    }

    enum CheckResult {
        case upToDate
        case ready(Prepared)
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // メインスレッドで読み書きする
    private(set) var state: State = .idle {
        didSet { onStateChange?() }
    }
    var onStateChange: (() -> Void)?

    private var timer: Timer?
    private var inFlight = false

    private enum Defaults {
        static let autoCheck = "UpdateAutoCheckEnabled"
        static let lastCheck = "UpdateLastCheckDate"
    }
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Defaults.autoCheck) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Defaults.autoCheck) }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": "ChromeStage/\(AppVersion.current.version)",
            "Accept": "application/vnd.github+json",
        ]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - 定期チェック

    // 起動後しばらくして 1 回、以降は 1 時間ごとに「前回から 24 時間経ったか」を見て確認する
    func startPeriodicChecks() {
        cleanUpWorkDirectory(after: 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard autoCheckEnabled else { return }
        if case .ready = state { return }
        if let last = UserDefaults.standard.object(forKey: Defaults.lastCheck) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { @MainActor in _ = await self.checkAndPrepare() }
    }

    // MARK: - チェック → ダウンロード → 検証

    // 最新リリースを確認し、新しければダウンロードして検証まで行う。同時実行は 1 つだけ
    @MainActor
    func checkAndPrepare() async -> CheckResult {
        if case .ready(let prepared) = state { return .ready(prepared) }
        guard !inFlight else { return .failed("更新の確認はすでに実行中です。") }
        inFlight = true
        defer { inFlight = false }

        state = .checking
        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: Defaults.lastCheck)
            guard Self.isNewer(release.version, than: AppVersion.current.version) else {
                Log.update.info("更新なし(最新: \(release.version, privacy: .public))")
                state = .idle
                return .upToDate
            }
            Log.update.info("新しいバージョンを検出: \(release.version, privacy: .public)")
            state = .downloading(version: release.version)
            let prepared = try await download(release)
            state = .ready(prepared)
            return .ready(prepared)
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            Log.update.error("更新処理に失敗: \(message, privacy: .public)")
            state = .failed(message)
            return .failed(message)
        }
    }

    struct Release {
        let version: String
        let zipURL: URL
        let checksumURL: URL
    }

    private struct ReleaseJSON: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static let maxZipSize = 100 * 1024 * 1024

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("最新バージョンの情報を取得できませんでした(HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))。")
        }
        let json = try JSONDecoder().decode(ReleaseJSON.self, from: data)
        return try Self.parseRelease(json)
    }

    private static func parseRelease(_ json: ReleaseJSON) throws -> Release {
        guard !json.draft, !json.prerelease else { throw UpdateError("公開済みの正式リリースが見つかりません。") }
        let version = String(json.tag_name.dropFirst())
        guard json.tag_name.hasPrefix("v"), parseVersion(version) != nil else {
            throw UpdateError("リリースのバージョン表記を解釈できません。")
        }
        func asset(_ name: String) throws -> URL {
            guard let a = json.assets.first(where: { $0.name == name }),
                  let url = URL(string: a.browser_download_url),
                  url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix("/\(repository)/releases/download/") else {
                throw UpdateError("リリースに \(name) がありません。")
            }
            if name.hasSuffix(".zip"), a.size > maxZipSize { throw UpdateError("配布 ZIP のサイズが想定を超えています。") }
            return url
        }
        return Release(
            version: version,
            zipURL: try asset("ChromeStage-\(version).zip"),
            checksumURL: try asset("ChromeStage-\(version).zip.sha256")
        )
    }

    private func download(_ release: Release) async throws -> Prepared {
        let workDir = try Self.freshWorkDirectory(for: release.version)

        let (checksumData, checksumResponse) = try await session.data(from: release.checksumURL)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
              let checksumText = String(data: checksumData.prefix(1024), encoding: .utf8),
              let expected = Self.parseChecksum(checksumText) else {
            throw UpdateError("チェックサムを取得できませんでした。")
        }

        let (tempURL, zipResponse) = try await session.download(from: release.zipURL)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("配布 ZIP をダウンロードできませんでした。")
        }
        let zipURL = workDir.appendingPathComponent("ChromeStage-\(release.version).zip")
        try FileManager.default.moveItem(at: tempURL, to: zipURL)

        return try await Task.detached(priority: .utility) {
            try Self.verifyAndExtract(zipURL: zipURL, expectedSHA256: expected,
                                      version: release.version, workDir: workDir)
        }.value
    }

    // ZIP のチェックサム検証 → 展開 → コード署名・公証・バージョンの検証
    static func verifyAndExtract(zipURL: URL, expectedSHA256: String, version: String, workDir: URL) throws -> Prepared {
        guard try sha256(of: zipURL) == expectedSHA256 else {
            throw UpdateError("ダウンロードしたファイルのチェックサムが一致しません。")
        }
        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let ditto = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path])
        guard ditto.status == 0 else { throw UpdateError("ZIP を展開できませんでした。") }

        guard let appURL = findApp(in: extracted) else { throw UpdateError("ZIP に ChromeStage.app が含まれていません。") }
        try verifyApp(at: appURL, expectedVersion: version)
        return Prepared(version: version, appURL: appURL)
    }

    private static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for item in top {
            if item.lastPathComponent == "ChromeStage.app" { return item }
            if item.lastPathComponent == "__MACOSX" { continue }
            let nested = item.appendingPathComponent("ChromeStage.app")
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    // 更新として採用してよいアプリかを検証する
    static func verifyApp(at appURL: URL, expectedVersion: String) throws {
        // 1. コード署名: このアプリの Developer ID Application 署名(同じ Team ID)であること
        try verifySignature(at: appURL)

        // 2. Gatekeeper: 公証済みであること
        let spctl = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", appURL.path])
        guard spctl.status == 0 else { throw UpdateError("公証の検証に失敗しました(Gatekeeper が承認しませんでした)。") }

        // 3. バージョン: リリースの表記と一致し、実行中より新しいこと(ダウングレード・すり替えの防止)
        let info = Bundle(url: appURL)?.infoDictionary
        guard info?["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("アプリのバージョンがリリースの表記と一致しません。")
        }
        guard isNewer(expectedVersion, than: AppVersion.current.version) else {
            throw UpdateError("実行中のバージョン以下の更新は適用しません。")
        }
    }

    static var requirementString: String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func verifySignature(at appURL: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("アプリの署名を読み取れませんでした。")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError("署名要件を作成できませんでした。")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            throw UpdateError("コード署名が一致しません。このアプリの Developer ID 署名ではないため、更新を中止しました。")
        }
    }

    // MARK: - インストール

    // 検証済みの更新で実行中のアプリを置き換えて再起動する。
    // アプリ自身が終了した後に、固定内容のシェルスクリプトが入れ替えと再起動を行う。
    // 置き換え先に書き込めない場合などは、理由を返して何も変更しない
    @discardableResult
    func install(_ prepared: Prepared, terminateApp: Bool = true) -> String? {
        let dest = Bundle.main.bundleURL
        if dest.path.contains("/DerivedData/") || dest.path.contains("/Build/Products/") {
            return "開発用ビルドから起動しているため、自動では置き換えません。"
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            return "\(dest.deletingLastPathComponent().path) に書き込めないため、自動では置き換えられません。ダウンロードした新しいアプリを手動で置き換えてください。"
        }
        do {
            let workDir = prepared.appURL.deletingLastPathComponent().deletingLastPathComponent()
            let script = workDir.appendingPathComponent("install.sh")
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                                 prepared.appURL.path, dest.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            return "更新の準備に失敗しました: \(error.localizedDescription)"
        }
        Log.update.info("置き換えスクリプトを起動。更新のためアプリを終了する(\(prepared.version, privacy: .public))")
        if terminateApp { NSApp.terminate(nil) }
        return nil
    }

    // 引数: <終了を待つ PID> <新しい .app> <置き換え先の .app>
    // 一時コピー → 旧版を退避 → 入れ替え、のどこかで失敗したら旧版へ戻す
    private static let installScript = """
    #!/bin/sh
    pid="$1"; new="$2"; dest="$3"
    tmp="${dest}.update-new"; old="${dest}.update-old"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i+1))
      [ "$i" -gt 120 ] && exit 1
      sleep 0.5
    done
    rm -rf "$tmp" "$old"
    if ! /usr/bin/ditto "$new" "$tmp"; then rm -rf "$tmp"; /usr/bin/open "$dest"; exit 1; fi
    if ! mv "$dest" "$old"; then rm -rf "$tmp"; /usr/bin/open "$dest"; exit 1; fi
    if mv "$tmp" "$dest"; then rm -rf "$old"; else mv "$old" "$dest"; fi
    /usr/bin/open "$dest"
    """

    // MARK: - ヘッドレス実行(開発・検証用)

    // `--check-update`: 確認 → ダウンロード → 検証まで。`--update`: さらに置き換えて再起動する。
    // UI を起動せず結果を標準出力へ出す(置き換えスクリプトは自プロセスの終了を待つ)
    static func runCLI(install: Bool) -> Never {
        Task { @MainActor in
            let service = UpdateService.shared
            print("実行中: \(AppVersion.current.summary)")
            switch await service.checkAndPrepare() {
            case .upToDate:
                print("最新バージョンです")
                exit(0)
            case .failed(let message):
                print("失敗: \(message)")
                exit(1)
            case .ready(let prepared):
                print("検証済みの更新: \(prepared.version)(\(prepared.appURL.path))")
                if install {
                    if let reason = service.install(prepared, terminateApp: false) {
                        print("置き換えできません: \(reason)")
                        exit(1)
                    }
                    print("置き換えを開始しました(このプロセスは終了します)")
                }
                exit(0)
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    // MARK: - 作業ディレクトリ

    private static var updatesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChromeStage/Updates", isDirectory: true)
    }

    // <Updates>/<version>/ を空の状態で作る(過去の残骸は消す)
    private static func freshWorkDirectory(for version: String) throws -> URL {
        let dir = updatesDirectory.appendingPathComponent(version, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 更新後の初回起動などで残った作業ファイルを消す(置き換えスクリプトが終わるのを待つ)
    private func cleanUpWorkDirectory(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: Self.updatesDirectory)
        }
    }

    // MARK: - 純粋なユーティリティ(selftest 対象)

    // "1.2.3" → [1, 2, 3]。数字とドットだけの 1〜4 要素のみ受け付ける
    static func parseVersion(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parseVersion(candidate), var b = parseVersion(current) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    // `shasum -a 256` 形式("<64桁の16進>  <ファイル名>")から先頭のハッシュを取り出す
    static func parseChecksum(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first, token.count == 64,
              token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
