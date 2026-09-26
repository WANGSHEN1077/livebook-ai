import XCTest
@testable import LiveBookAI

final class ISBNParserTests: XCTestCase {
    // MARK: - Checksum

    func testISBN10ChecksumValid() {
        // 0-306-40615-2
        XCTAssertTrue(ISBNParser.isbn10ChecksumValid("0306406152"))
        // 0-85131-041-9
        XCTAssertTrue(ISBNParser.isbn10ChecksumValid("0851310419"))
        // Invalid check digit.
        XCTAssertFalse(ISBNParser.isbn10ChecksumValid("0306406153"))
        XCTAssertFalse(ISBNParser.isbn10ChecksumValid("030640615"))
    }

    func testISBN10CheckDigitX() {
        // 0-8044-2957-X
        XCTAssertTrue(ISBNParser.isbn10ChecksumValid("080442957X"))
        XCTAssertTrue(ISBNParser.isbn10ChecksumValid("080442957x"))
    }

    func testISBN13ChecksumValid() {
        // 978-3-16-148410-0
        XCTAssertTrue(ISBNParser.isbn13ChecksumValid("9783161484100"))
        // 978-0-306-40615-7
        XCTAssertTrue(ISBNParser.isbn13ChecksumValid("9780306406157"))
        XCTAssertFalse(ISBNParser.isbn13ChecksumValid("9780306406158"))
        XCTAssertFalse(ISBNParser.isbn13ChecksumValid("97831614841"))  // too short
    }

    // MARK: - Parse from text

    func testParseISBN13FromLabel() {
        let isbn = ISBNParser.parse(from: "ISBN 9787108025302")
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.kind, .isbn13)
        XCTAssertEqual(isbn?.digits, "9787108025302")
        XCTAssertTrue(isbn?.isValid ?? false)
        XCTAssertTrue(isbn?.isISBN ?? false)
    }

    func testParseISBN13WithHyphens() {
        let isbn = ISBNParser.parse(from: "ISBN 978-3-16-148410-0")
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.kind, .isbn13)
        XCTAssertEqual(isbn?.digits, "9783161484100")
    }

    func testParseISBN10FromLabel() {
        let isbn = ISBNParser.parse(from: "ISBN 0-306-40615-2")
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.kind, .isbn10)
        XCTAssertEqual(isbn?.digits, "0306406152")
    }

    func testParseISBN10EndingX() {
        let isbn = ISBNParser.parse(from: "ISBN 0-8044-2957-X")
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.kind, .isbn10)
        XCTAssertEqual(isbn?.digits, "080442957X")
    }

    func testParseEAN13WithoutISBNPrefix() {
        // A 13-digit EAN not starting with 978/979 → EAN-13.
        let isbn = ISBNParser.parse(from: "EAN 5901234123457")
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.kind, .ean13)
        XCTAssertEqual(isbn?.digits, "5901234123457")
        XCTAssertFalse(isbn?.isISBN ?? true)
    }

    func testParseInvalidRejected() {
        XCTAssertNil(ISBNParser.parse(from: "ISBN 9783161484101"))  // bad checksum
        XCTAssertNil(ISBNParser.parse(from: "no digits here"))
        XCTAssertNil(ISBNParser.parse(from: "ISBN 12345"))
    }

    func testParseEmbeddedInSentence() {
        let text = "这本书的条码是 9787108025302 请留意"
        let isbn = ISBNParser.parse(from: text)
        XCTAssertNotNil(isbn)
        XCTAssertEqual(isbn?.digits, "9787108025302")
    }

    func testDisplayString() {
        let isbn = ISBNParser.parse(from: "978-3-16-148410-0")
        XCTAssertTrue(isbn?.display.hasPrefix("ISBN") ?? false)
        let cleaned = isbn?.display.replacingOccurrences(of: "-", with: "").filter { $0.isNumber }
        XCTAssertEqual(cleaned, "9783161484100")
    }
}
