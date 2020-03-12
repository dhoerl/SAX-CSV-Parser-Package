//
//  XCTest_Stream.swift
//  
//
//  Created by David Hoerl on 2/20/20.
//

import Foundation
import XCTest
@testable import SAX_CSV_Parser

private struct Foo  {
	let x: Bool
	let y: String?
	let z: Date
	let a: UUID
	let i: Int

	var record: Int = 0
	var defaults: Set<String>?
}
extension Foo: Encodable, Decodable, CSVDecode, Equatable {
	static var defaultValues: CSVDecode {
		// Optionals need a value (so the type can be ascertained), but won't actually get defaulted if the CSV returns nil
		return Foo(x: true, y: "Fooy", z: Date(), a: UUID(), i: 5000)
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

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
        //print("TEST:", items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
#endif
}

private let TestAssetQueue = DispatchQueue(label: "com.AssetFetcher", qos: .userInitiated)


final class XCTest_Stream: XCTestCase, StreamDelegate {

    private var expectation = XCTestExpectation(description: "")
    private var assetQueue = TestAssetQueue

	private var p: CSVParser!
	private var defaults = Foo.defaultValues
	private var newParser: CSVParser! { CSVParser(streamDelegate: self, configuration: config, defaults: defaults) }
	private var config: CSVConfiguration = CSVConfiguration()

	private var objects: [CSVDecode] = []
	private var events = 0

	private let headers: [String] = ["xx", "yy", "zz", "aa", "ii"]

	
    override func setUp() {
        continueAfterFailure = false

        events = 0
        objects.removeAll()

        p = newParser
        assetQueue.sync { self.p.open() }
        XCTAssertEqual(events, 1)
    }

    override func tearDown() {
		config = CSVConfiguration()	// it may get mutated after setup()
        expectation = XCTestExpectation(description: "")
        p = nil
    }

	private func buildData(lines: [[String]]) -> String {
		var str = ""
		lines.forEach { (line) in
			if !str.isEmpty { str += "\n" }
			str += line.joined(separator: ",")
		}
		return str
	}

	// MARK: - Tests -

	func test_000_Simple() {
		let date = Date()
		let uuid = UUID()
		let oneLine: [String] = [ "Yes", "Gaga", "\(date.timeIntervalSinceReferenceDate)", "\(uuid.uuidString)", "\(-20)"]
		let str = buildData(lines: [headers, oneLine]) + "\n"
print("STR", str)
		let expected = Foo(x: true, y: "Gaga", z: date, a: uuid, i: -20)

		CSVParser.enableLogging = true
		runTest(msg: str)
		assetQueue.sync { self.p.close() }

		let results = p.currentObjects()
		XCTAssertEqual(results.count, 1)
		guard let result = results[0] as? Foo else { return XCTFail() }
		XCTAssertEqual(result, expected)
	}

    private func runTest(msg _msg: String, strip: Bool = false) {
		var msg = _msg

		msg.withUTF8 { (buffer: UnsafeBufferPointer<UInt8>) -> Void in
			let _ = assetQueue.sync {
				self.p.write(buffer.baseAddress!, maxLength: buffer.count)
			}
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

    @objc
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        //dispatchPrecondition(condition: .onQueue(assetQueue))
        guard let stream = aStream as? OutputStream else { fatalError() }

        events += 1
        var closeStream = false

        switch eventCode {
        case .openCompleted:
            XCTAssertEqual(events, 1)
        case .endEncountered:
            closeStream = true
        case .hasBytesAvailable, .hasSpaceAvailable:
			break
        case .errorOccurred:
            aStream.close()
            if let error = aStream.streamError {
                print("WTF!!! Error:", error)
            } else {
                print("ERROR BUT NO STREAM ERROR!!!")
            }
            closeStream = true
        default:
            print("UNEXPECTED \(eventCode)", String(describing: eventCode))
            XCTAssert(false)
        }
        if closeStream {
            stream.close()

            DispatchQueue.main.async {
                self.expectation.fulfill()
            }
        }
    }

}

#if false
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

#endif
