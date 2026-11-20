import Foundation
import CoreGraphics

// CGRect の JSON 永続化用ラッパー
struct CodableRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum SlotState: String, Codable {
    case visible // ステージ上に表示中
    case parked  // 画面端へ退避中
    case missing // 対応するウィンドウが見つからない(Chrome 終了・ウィンドウを閉じた等)
}

// 永続化する Slot 情報。
// 方針(CLAUDE.md): ウィンドウタイトルや URL は保存しない。
struct ChromeSlotRecord: Codable {
    var id: UUID
    var displayName: String

    // macWindowID は Chrome 起動中のみ有効な一時 ID として扱う(再起動後は再照合が必要)
    var macWindowID: UInt32?
    var pid: Int32?

    var lastVisibleRect: CodableRect?

    // 退避中のウィンドウを実際に置いた座標(park 時に記録し、unpark で消す)。
    // Chrome 終了でウィンドウを見失っても残し、「退避中だった slot」の目印にも使う
    var parkedRect: CodableRect?

    // Chrome 終了などでウィンドウを見失った時点の最終既知フレーム。
    // Chrome は再起動時に各ウィンドウを保存済み座標(を作業領域に収めた位置)へ復元するため、
    // これを手がかりに slot と再照合する。再照合の成功か、手動の割り当て/解除で消える
    var lastKnownRect: CodableRect?

    var state: SlotState
    var createdAt: Date
    var updatedAt: Date
}

// 実行時の Slot(永続レコード + AX ウィンドウ参照)
final class Slot {
    var record: ChromeSlotRecord
    var axWindow: AXWindow?

    init(record: ChromeSlotRecord, axWindow: AXWindow? = nil) {
        self.record = record
        self.axWindow = axWindow
    }
}

struct StageSessionRecord: Codable {
    var activeSlotID: UUID?
    var stageRect: CodableRect?
    var slots: [ChromeSlotRecord]

    // stageRect を保存した時点のディスプレイ構成(識別子)と、構成ごとに覚えている stage rect。
    // 1 画面 ⇄ 2 画面の切り替えで、ウィンドウを構成ごとの定位置へ自動で戻すために使う。
    // 旧バージョンのセッションには無いため optional
    var displaySignature: String?
    var stageRectsByDisplays: [String: CodableRect]?
}

// セッションの JSON 永続化。
// 保存先: ~/Library/Application Support/ChromeStage/session.json
final class StageSessionStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ChromeStage", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("session.json")
        }
    }

    func load() -> StageSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StageSessionRecord.self, from: data)
        } catch {
            Log.stage.error("セッション読み込み失敗: \(error, privacy: .public)")
            return nil
        }
    }

    func save(_ session: StageSessionRecord) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: fileURL, options: .atomic)
        } catch {
            Log.stage.error("セッション保存失敗: \(error, privacy: .public)")
        }
    }
}
