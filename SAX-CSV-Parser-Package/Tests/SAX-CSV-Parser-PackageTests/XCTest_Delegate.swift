//
//  XCTest_Delegate.swift
//  
//
//  Created by David Hoerl on 2/24/20.
//

import Foundation
import XCTest
@testable import SAX_CSV_Parser_Package

private enum DelMethods: Int, CustomStringConvertible {
	case begin, end, beginLine, endLine, readField, didFailWithError

	var description: String { String(self.rawValue) }
}
private let NIL = "nil"

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
        //print("TEST:", items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
#endif
}

final class XCTest_Delegate: XCTestCase {

    private var expectation = XCTestExpectation(description: "")

	private var p: CSVParser!
	private var newParser: CSVParser! { CSVParser(traditionalDelegate: self, configuration: config) }
	private var config: CSVConfiguration = CSVConfiguration()
	// Response data
	private var delegateMessages: [DelMethods] = []
	private var fields: [String] = []
	private var lines: [[String]] = []

    override func setUp() {
        continueAfterFailure = false

        delegateMessages.removeAll()
        fields.removeAll()
        lines.removeAll()
    }

    override func tearDown() {
		config = CSVConfiguration()	// it may get mutated after setup()
        expectation = XCTestExpectation(description: "")
    }

	// MARK: - Tests -

    func test000_ASCII() {
		p = newParser

		p.open()
		runTest(msg: ASCIItable)
		XCTAssert(p.streamError == nil)
		p.close()

		tearDown()
		setUp()

		config = CSVConfiguration(removeWhiteSpace: false)
		p = newParser

		p.open()
		runTest(msg: ASCIItable)
		XCTAssert(p.streamError == nil)
		p.close()
    }

    func xtest_010_NoField() {
		let csvStrings = ["", "\n", "   ", "   \n"]
		let expectedMessages: [DelMethods] = [.begin, .end]
		let expectedLines: [[String]] = []

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [expectedLines])
    }

    func xtest_011_NilAndNull() {
		let csvStrings = [
			"\"\",",
			" \"\",",
			"\"\" , ",
			" \"\" ,  "
		]
		let expectedMessages: [DelMethods] = [.begin, .beginLine, .readField,  .readField, .endLine, .end]
		let expectedLines: [String] = ["", NIL]

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [[expectedLines]])

		let rCsvStrings: [String] = csvStrings.map({ String($0.reversed()) })
		loopTest(msgs: rCsvStrings, expectedMessages: expectedMessages, expectedLines: [[expectedLines.reversed()]])
    }

    func xtest_020_DoubleQuotes() {
		//let csv = "Howdie,WOW\nGowie,Fooper,Glom\n"
		let csvStrings = [
			"\"xxx\"\"xxx\"\"xxx\"",
			"\"xxx\"\"xxx\"\"\"",
			"\"xxx\"\"xxx\"\"\"\"\"",
			"\"\"\"xxx\"\"xxx\"",
			"\"\"\"\"\"xxx\"\"xxx\"",
			"\"\"\"\"\"\""
		]
		let expectedMessages: [DelMethods] = [.begin, .beginLine, .readField, .endLine, .end]
		let expectedLines: [[[String]]] = [
			[[#"xxx"xxx"xxx"#]],
			[[#"xxx"xxx""#]],
			[[#"xxx"xxx"""#]],
			[["\"xxx\"xxx"]],
			[["\"\"xxx\"xxx"]],
			[["\"\""]],
		]

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: expectedLines)
    }

    func xtest_012_ExcelSpecial() {
		let csvStrings = [#"="000333""#, "\"=\"\"000333\"\"\""]
		//let csvStrings = ["\"=\"\"000333\"\"\""]
		let expectedMessages: [DelMethods] = [.begin, .beginLine, .readField,  .endLine, .end]
		let expectedLines: [String] = ["000333"]

		config = CSVConfiguration(excelSpecial: true)
		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [[expectedLines]], config: config)
    }

    func xtest_020_SingleField() {
		//let csv = "Howdie,WOW\nGowie,Fooper,Glom\n"
		let csvStrings = ["Howdie",  "   Howdie","Howdie   ","   Howdie   ", "Howdie\n", "Howdie   \n"]
		let expectedMessages: [DelMethods] = [.begin, .beginLine, .readField, .endLine, .end]
		let expectedLines: [[String]] = [["Howdie"]]

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [expectedLines])
    }

    private func loopTest(msgs: [String], expectedMessages: [DelMethods], expectedLines el: [[[String]]], config: CSVConfiguration = CSVConfiguration()) {
		for (idx, csv) in msgs.enumerated() {
			setUp()

			self.config = config
			p = newParser

			p.open()
			runTest(msg: csv)
			p.close()

			let expectedLines = el[el.count > 1 ? idx : 0]
if delegateMessages != expectedMessages {
	print("STRING[\(idx)]: >\(csv)<")
	print("EXPECTED:", expectedMessages)
	print("GOT    :", delegateMessages)
}
			XCTAssertEqual(delegateMessages, expectedMessages)

if lines != expectedLines {
	print("STRING[\(idx)]: >\(csv)<")
	print("EXPECTED:", expectedLines)
	print("GOT    :", lines)
}
			XCTAssertEqual(lines, expectedLines)

			tearDown()
		}
	}
    private func runTest(msg _msg: String, strip: Bool = false) {
		var msg = _msg

		msg.withUTF8 { (buffer: UnsafeBufferPointer<UInt8>) -> Void in
			let _ = self.p.write(buffer.baseAddress!, maxLength: buffer.count)
		}

//		var expectedFulfillmentCount = 0
//
//        wait(for: [expectation], timeout: TimeInterval(files.count * 10))
//
//        var values: [ByURL] = []
//        self.assetQueue.sync {
//            self.fetchers.values.forEach({ values.append($0) })
//        }
//        for byURL in values {
//            XCTAssert( !byURL.data.isEmpty )
//            XCTAssert( byURL.image != nil )
//        }
    }
}

extension XCTest_Delegate: CSVParserProtocol {

	func csvParserDidBeginDocument() {
		LOG("csvParserDidBeginDocument")
		delegateMessages.append(.begin)
	}
	func csvParserDidEndDocument() {
		LOG("csvParserDidEndDocument")
		delegateMessages.append(.end)
	}
	func csvParserDidBeginLine(recordNumber: Int) {
		LOG("csvParserDidBeginLine \(recordNumber)")
		delegateMessages.append(.beginLine)
	}
	func csvParserDidEndLine(recordNumber: Int) {
		LOG("csvParserDidEndLine \(recordNumber)")

		delegateMessages.append(.endLine)
		lines.append(fields)
		fields.removeAll()
	}
	func csvParserDidReadField(field _field: String?, atIndex fieldIndex: Int) {
		let field = _field ?? NIL
		LOG("csvParserDidReadField \(field)", "atIndex: \(fieldIndex)")
		delegateMessages.append(.readField)
		fields.append(field)
//print("FIELD:", field)
//print("FIELDS:", fields)
	}
	func csvParserDidFail(error: NSError) {
		LOG("csvParserDidFailWithError \(error)")
		delegateMessages.append(.didFailWithError)
	}

}

//extension XCTest_Delegate_WS: CSVParserProtocol {
//}
