//
//  XCTest_Decoder.swift
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
// Equatable only needed for the tests
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

final class XCTest_Decoder: XCTestCase {

    private var expectation = XCTestExpectation(description: "")

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

	func test_000_Decode() {
		let h = ["xx", "yy", "zz", "aa", "ii"]
		let ti = Date().timeIntervalSinceReferenceDate
		let uu = UUID().uuidString

		// see default object above - Foo(x: true, y: "Fooy", z: Date(), a: UUID(), i: 0)
		let input: [[String: String?]] = [
			[
				"x": 	nil,
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	Optional.none
			],
			[
				"x": 	"1",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
			[
				"x": 	"true",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
			[
				"x": 	"YES",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
		]

		let output: [Foo] = [
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55, defaults: ["x", "i"]),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
		]
		for i in 0..<input.count {
			do {
				let d = try CSVDecoder(defaults: Foo.defaultValues, headers: h)

				let scanned = input[i]
				let expected = output[i]

				let obj = try d.decode(record: 55, from: scanned)
				guard let result = obj as? Foo else { return XCTFail() }

				//print("DECODED:", result)
				//print("EXPECT:", expected)

				XCTAssertEqual(result, expected)
			} catch {
				print("ERROR:", error)
				XCTFail()
			}
		}
	}

	func test_001_Decode() {
		let h = ["xx", "yy", "zz", "aa", "ii"]
		let ti = Date().timeIntervalSinceReferenceDate
		let uu = UUID().uuidString

		// see default object above - Foo(x: true, y: "Fooy", z: Date(), a: UUID(), i: 0)
		let input: [[String: String?]] = [
			[
				"x": 	nil,
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	Optional.none
			],
			[
				"x": 	"0",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
			[
				"x": 	"false",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
			[
				"x": 	"NO",
				"y":	"GAGA",
				"z":	"\(ti)",
				"a":	"\(uu)",
				"i":	"5000"
			],
		]

		let output: [Foo] = [
			Foo(x: false, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55, defaults: ["x", "i"]),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
			Foo(x: true, y: "GAGA", z: Date(timeIntervalSinceReferenceDate: ti), a: UUID(uuidString: uu)!, i: 5000, record: 55),
		]
		for i in 0..<input.count {
			do {
				let d = try CSVDecoder(defaults: Foo.defaultValues, headers: h)

				let scanned = input[i]
				let expected = output[i]

				let obj = try d.decode(record: 55, from: scanned)
				guard let result = obj as? Foo else { return XCTFail() }

				//print("DECODED:", result)
				//print("EXPECT:", expected)

				XCTAssertNotEqual(result, expected)
			} catch {
				print("ERROR:", error)
				XCTFail()
			}
		}
	}

}
