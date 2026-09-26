import Foundation

// MARK: - Phase 1 protocol stubs for future phases.
// Phase 1 不实现这些功能（规格 #32-#38），仅保留抽象，后续阶段接入。

/// 系统音频 → ASR 字幕（Phase 2）。
protocol ASRProvider: AnyObject {
    var onTranscript: (@Sendable (String, TimeInterval, Float) -> Void)? { get set }
    func start()
    func stop()
}

/// 成交/流标打印（Phase 5）。
protocol PrinterProvider: AnyObject {
    func printOrder(bookTitle: String, isbn: String?, buyer: String, price: Int, orderID: String) throws
}

/// Book Matrix 匹配（Phase 6）。
protocol BookMatrixClient: AnyObject {
    func findByISBN(_ isbn: String) async throws -> BookMatrixRecord?
    func findByTitle(_ title: String) async throws -> [BookMatrixRecord]
    func findByImage(_ data: Data) async throws -> [BookMatrixRecord]
}

/// 通用书籍记录（Book Matrix 返回结构，Phase 6 启用后细化）。
struct BookMatrixRecord: Sendable {
    let id: String
    let title: String
    let isbn: String?
    let author: String?
    let publisher: String?
}
