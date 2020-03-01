//
//  XCTest_Stream.swift
//  
//
//  Created by David Hoerl on 2/20/20.
//

import Foundation
import XCTest
@testable import SAX_CSV_Parser_Package

private struct Foo  {
	let x: Bool
	let y: String?
	let z: Date
	let a: UUID
	let i: Int

	var record: Int = 0
	var defaults: [String]?
}
extension Foo: Encodable, Decodable, CSVDecode {
	static var defaultValues: CSVDecode {
		// Optionals need a value, but won't actually get defaulted if the CSV returns nil
		return Foo(x: true, y: "Fooy", z: Date(), a: UUID(), i: 0)
	}

	static var csvCodingKeys: [String: String] { [
		// Property		CSV_Header_Name
			"x":		"xx",
			"y":		"yy",
			"z":		"zz",
			"a":		"aa",
			"i":		"ii",

			"record":	recordNumberProperty,
			"defaults":	defaultedProperties
	] }
	func encode() throws -> Data {
		let encoder = JSONEncoder() // possibly customize
		return try Self.CSVencoder(encoder: encoder, from: self)
	}
	func decode(from: Data) throws -> CSVDecode {
		let decoder = JSONDecoder() // possibly customize
		return try Self.CSVdecoder(decoder: decoder, from: from) as Foo
	}
}

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

final class XCTest_Stream: XCTestCase, StreamDelegate {

    private var expectation = XCTestExpectation(description: "")

	private var p: CSVParser!
	private var newParser: CSVParser! { CSVParser(streamDelegate: self, configuration: config, defaults: defaults) }
	private var config: CSVConfiguration = CSVConfiguration()
	private var defaults: CSVDecode!
	private var headers: [String]!

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

	func test000() {
		do {
			let h = ["xx", "yy", "zz", "aa", "ii"]
			let d = try CSVDecoder(defaults: Foo.defaultValues, headers: h)
			//let f = Foo(x: false, y: "goofy", z: Date.distantFuture, a: UUID(), i: 22)

			let ti = Date().timeIntervalSinceReferenceDate
			let uu = UUID().uuidString
			let scanned: [String: String?] = [
				"x": 	nil,
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	Optional.none
			]

			let obj = try d.decode(record: 55, from: scanned)
			print("DECODED:", obj)
		} catch {
			print("ERROR:", error)
		}



		//let c = CSVDecoder(defaults: defaults, headers: [])
		//c.run()
	}

    func xtest000_ASCII() {
		p = newParser

		p.open()
		runTest(msg: ASCIItable)
		p.close()

		tearDown()
		setUp()

		config = CSVConfiguration(removeWhiteSpace: false)
		p = newParser

		p.open()
		runTest(msg: ASCIItable)
		p.close()
    }

    func xtest_010_NoField() {
		let csvStrings = ["", "\n", "   ", "   \n"]
		let expectedMessages: [DelMethods] = [.begin, .end]
		let expectedLines: [[String]] = []

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [expectedLines])
    }

    func xtest_011_NilAndNull() {
		let csvStrings = ["\"\",", " \"\",", "\"\" , ", " \"\" ,  "]
		let expectedMessages: [DelMethods] = [.begin, .beginLine, .readField, .readField, .endLine, .end]
		let expectedLines: [String] = ["", NIL]

		loopTest(msgs: csvStrings, expectedMessages: expectedMessages, expectedLines: [[expectedLines]])

		let rCsvStrings: [String] = csvStrings.map({ String($0.reversed()) })
		loopTest(msgs: rCsvStrings, expectedMessages: expectedMessages, expectedLines: [[expectedLines.reversed()]])
    }

    func xtest_020_DoubleQuotes() {
		//let csv = "Howdie,WOW\nGowie,Fooer,Glom\n"
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
		//let csv = "Howdie,WOW\nGowie,Fooer,Glom\n"
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
