//
//  StringComposer.swift
//  CSVParserInSwift
//
//  Created by David Hoerl on 2/18/20.
//  Copyright © 2020 David Hoerl. All rights reserved.
//

import Foundation

private let BufferAllocation = 32

private enum ASCII: UInt8 {
	case tab		=  9
	case space		= 32
	case quote		= 34
	case equal		= 61
}

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
        //print("COMPOSER:", items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
#endif
}

struct StringComposer {

	var isEmpty: Bool { length == 0 }
	var ignoreAppend = false			// suppress writing characters

	private var buffer = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
	private var length = 0
	private var maxLength = BufferAllocation
	private let mapExcelSpecial: Bool

	init(mapExcelSpecial: Bool) {
		self.mapExcelSpecial = mapExcelSpecial
		reInit()
	}

	private mutating func reInit() {
		buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: BufferAllocation)
		length = 0
		maxLength = BufferAllocation
	}

	private func isEraseable(_ c: UInt8, isStart: Bool) -> Bool {
		let ret: Bool

		switch c {
		case ASCII.space.rawValue:
			ret = true
		case ASCII.tab.rawValue:
			ret =  true
		case ASCII.equal.rawValue:
			ret = isStart && mapExcelSpecial
		default:
			ret =  false
		}
		return ret
	}

	mutating func append(c: UInt8) {
		guard ignoreAppend == false else { return }

		defer { buffer[length] = c; length += 1 }

		if length >= maxLength {
			maxLength += BufferAllocation
			let newBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxLength)
			newBuffer.assign(from: buffer, count: length)
			buffer.deallocate()
			buffer = newBuffer
		}
	}

	mutating func backSpace() {
		guard length > 0 else { return }
		length -= 1
	}

	mutating func removeTrailingSpace() {
		while length > 0 {
			guard isEraseable(buffer[length - 1], isStart: false) else { break }
			length -= 1
		}
	}

	// Happens when there is leading white space then a quote appears
	mutating func resetBuffer() throws {
		for i in 0..<length {
			let c = buffer[i]
			guard isEraseable(c, isStart: true) else {
				throw CSVbuildError(code: .charsBeforeQuote, description: "odd characters before the starting quote")
			}
		}
		length = 0
	}

	mutating func field(emptyStringForNil: Bool) throws -> String?  {
		defer { reInit() }

		//print("MAP:", mapExcelSpecial)
		//for i in 0..<length {
		//	print("CHAR:", String(Character(UnicodeScalar(buffer[i]))))
		//}
		if mapExcelSpecial, length > 3, buffer[0] == ASCII.equal.rawValue, buffer[1] == ASCII.quote.rawValue, buffer[length-1] == ASCII.quote.rawValue {
			let moveEnd = length - 2
			for i in 0..<moveEnd {
				buffer[i] = buffer[i+2]	// skip over "=("
			}
			length -= 3
		}

		switch length {
		case 0 where emptyStringForNil:
			return ""
		case 0:
			return nil
		default:
			let _s = String(bytesNoCopy: buffer, length: length, encoding: .utf8, freeWhenDone: true)
			guard let s = _s else {
				throw CSVbuildError(code: .stringConstructionFailed, description: "could not create string: probably incorrect Unicode")
			}
			LOG("Field:", s)
			return s
		}
	}

}

private extension Array {

	subscript(char: UInt8) -> Element {
		get {
		  return self[Int(char)]
		}
		set {
		  self[Int(char)] = newValue
		}
	  }

}
