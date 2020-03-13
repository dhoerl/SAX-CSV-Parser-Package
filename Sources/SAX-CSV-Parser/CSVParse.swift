//
//  CSVParse2.swift
//  CSVParserInSwift
//
//  Created by David Hoerl on 2/18/20.
//  Copyright © 2020 hoerl. All rights reserved.
//

import Foundation

public protocol CSVParserProtocol: class {
	func csvParserDidBeginDocument()
	func csvParserDidEndDocument()
	func csvParserDidBeginLine(recordNumber: Int)
	func csvParserDidEndLine(recordNumber: Int)
	func csvParserDidReadField(field: String?, atIndex fieldIndex: Int)
	func csvParserDidFail(error: NSError)
}
public extension CSVParserProtocol {
	func csvParserDidBeginDocument() { }
	func csvParserDidEndDocument() { }
	func csvParserDidBeginLine(recordNumber: Int) { }
	func csvParserDidEndLine(recordNumber: Int) { }
	func csvParserDidReadField(field: String?, atIndex fieldIndex: Int) { }
	func csvParserDidFail(error: NSError) { }
}

public struct CSVConfiguration {
	let delimiter: Character	// normally "," or TAB
	let hasHeader: Bool			// used when using Codable to create structs
	let removeWhiteSpace: Bool	// cleanup sloppy coding
	let excelSpecial: Bool		// '=(0001234) hack to preserve leading zeros
	let allowsComments: Bool	// if '#'is the first character, then ignore that line

	init(delimiter: Character = ",", hasHeader: Bool = true, removeWhiteSpace: Bool = false, excelSpecial: Bool = false, allowsComments: Bool = false) {
		self.delimiter = delimiter
		self.hasHeader = hasHeader
		self.removeWhiteSpace = removeWhiteSpace
		self.excelSpecial = excelSpecial
		self.allowsComments = allowsComments

		//assert(!(removeWhiteSpace && delimiter == Character(unicodeScalarLiteral: ASCII.tab)))
		assert(!(removeWhiteSpace && delimiter.asciiValue == Character("\t").asciiValue!))
	}

	var delim: UInt8 { delimiter.asciiValue ?? Character(",").asciiValue! }
}

public enum CSVError: Int {
	case charsBeforeQuote = 100
	case notEnoughFields
	case quoteMissCount
	case incorrectFieldCount
	case extraneousChars
	case stringConstructionFailed
	case nonPrintingChar
}

public protocol CSVDecode: Decodable {
	static var defaultValues: CSVDecode { get }			// You create this and provide it on demand.
	static var csvCodingKeys: [String: String] { get }	// All properties - JSON decoding requires it.
	static var boolFalseStrings: Set<String> { get }	// lower case and/or numbers that constitute "false". Default is supplied.

	func encode() throws -> Data
	func decode(from: Data) throws -> CSVDecode
}

// User provided block that takes a dictionary of the current record, keys are struct property names
public typealias CSVRecordScrubber = (_ currentValues: [String: String?]) -> [String: String?]

func CSVbuildError(code: CSVError, description: String) -> NSError {
	return NSError(domain:"com.csvParser", code: code.rawValue, userInfo:[NSLocalizedDescriptionKey : description])
}

private enum ASCII: UInt8, CaseIterable {
	case tab		=  9
	case nl			= 10
	case cr			= 13
	case space		= 32
	case quote		= 34
	case number		= 35
	case comma		= 44
}

private enum ParseState {
	case look4comment, insideComment, normal, quoteInsideString, quoteLookAtNextChar, quoteLookForEnd, closed, error
}

// Start String pointer, End string pointer
private typealias ParseFunc = () -> Void

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
	if CSVParser.enableLogging {
		print("CSV:", items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
	}
#endif
}


public final class CSVParser: OutputStream {
	static var enableLogging = false

	private lazy var specialChars: [UInt8] = { [config.delimiter.asciiValue!, ASCII.quote.rawValue, ASCII.space.rawValue, ASCII.tab.rawValue, ASCII.cr.rawValue, ASCII.nl.rawValue, ASCII.number.rawValue] }()
	private var parseActions: [ParseFunc?] = Array<ParseFunc?>(repeating: nil, count: 256)

	private var _streamStatus: Stream.Status = .notOpen
	private var _streamError: NSError?

	private var parseState: ParseState {
		willSet {
			guard parseState != .error else { return }
			//guard parseState != newValue else { return }
			self.specialChars.forEach({ self.parseActions[$0] = nil })
			LOG(" <end>\n")
			switch newValue {
			case .look4comment:
				parseActions[ASCII.number.rawValue] = parseNumber
				parseActions[ASCII.nl.rawValue] = parseCommentNL
				processChar = processNotNumberChar
				LOG("State: LookForComment")
			case .insideComment:
				parseActions[ASCII.nl.rawValue] = parseCommentNL
				processChar = processIgnoreChar
				LOG("State: IgnoreComment")
			case .normal:
				parseActions[ASCII.quote.rawValue] = parseQuoteFirst
				parseActions[config.delim] = parseDelimiter
				parseActions[ASCII.cr.rawValue] = parseCR
				parseActions[ASCII.nl.rawValue] = parseNL
				processChar = config.removeWhiteSpace ? processEatWhiteSpaceChar : processNormalChar
				LOG("State: Normal")
			case .quoteInsideString:
				parseActions[ASCII.quote.rawValue] = parseQuoteLatter
				processChar = processNormalChar
				LOG("State: QuoteInsideString \(quoteCount)")
			case .quoteLookAtNextChar:
				parseActions[ASCII.quote.rawValue] = parseQuoteSecond // if quote, go back to "quoteInsideString"
				parseActions[config.delim] = parseDelimiter
				parseActions[ASCII.cr.rawValue] = parseCR
				parseActions[ASCII.nl.rawValue] = parseNL
				parseActions[ASCII.space.rawValue] = parseSpaceAfterClosingQuote	// goto quoteLookForEnd
				parseActions[ASCII.tab.rawValue] = parseSpaceAfterClosingQuote // quoteLookForEnd
				processChar = processPostQuotedStringIllegalChar	// any other char error!
				LOG("State: QuoteLookAtNextChar")
			case .quoteLookForEnd:
				parseActions[ASCII.quote.rawValue] = parseQuoteLatter
				parseActions[config.delim] = parseDelimiter
				parseActions[ASCII.cr.rawValue] = parseCR
				parseActions[ASCII.nl.rawValue] = parseNL
				parseActions[ASCII.space.rawValue] = parseSpaceAfterClosingQuote	// goto quoteLookForEnd
				parseActions[ASCII.tab.rawValue] = parseSpaceAfterClosingQuote // quoteLookForEnd
				processChar = processPostQuotedStringIllegalChar
				LOG("State: QuoteLookForEnd \(quoteCount)")
			case .closed, .error:
				processChar = processIgnoreChar
				LOG("State: CLOSED or ERROR")
			}
		}
	}
	private var quoteCount = 0;
	private var numFields: Int = 0
	private var fieldNumber = 0
	private var recordCount: Int = 0
	private var composer: StringComposer
	private lazy var processChar: (UInt8) -> Void = processNormalChar

	private var headers: [String] = []
	private var fields: [String?] = []
	private var records: [[String?]] = []
	private var decodedObjs: [CSVDecode] = []

	private let config: CSVConfiguration
	private weak var traditionalDelegate: CSVParserProtocol!

	private weak var _streamDelegate: StreamDelegate?
	private let recordScrubber: CSVRecordScrubber?
	private var csvDecoder: CSVDecoder?
	private let defaults: CSVDecode?

	// MARK: - Public -

	init(traditionalDelegate: CSVParserProtocol?, configuration: CSVConfiguration = CSVConfiguration()) {
		self.traditionalDelegate = traditionalDelegate
		config = configuration
		composer = StringComposer(mapExcelSpecial: config.excelSpecial)
		parseState = .quoteLookAtNextChar
		// open() triggers willSet

		self.defaults = nil
		self.recordScrubber = nil

		super.init(toMemory: ())
		//super.init(toBuffer buffer: UnsafeMutablePointer<UInt8>(bitmap: 1) capacity: Int)
	}

	init(streamDelegate: StreamDelegate, configuration: CSVConfiguration = CSVConfiguration(), defaults: CSVDecode, recordScrubber: CSVRecordScrubber? = nil) {
		_streamDelegate = streamDelegate
		config = configuration
		self.defaults = defaults
		self.recordScrubber = recordScrubber

		composer = StringComposer(mapExcelSpecial: config.excelSpecial)
		_streamStatus = .notOpen
		parseState = .quoteLookAtNextChar
		// open() triggers willSet

		super.init(toMemory: ())
	}

	public func currentFields() -> [String?] {
		let value = fields
		fields.removeAll()
		return value
	}

	public func currentRecords() -> [[String?]] {
		let value = records
		records.removeAll()
		return value
	}

	public func currentObjects() -> [CSVDecode] {
		let value = decodedObjs
		decodedObjs.removeAll()
		return value
	}

	private func initializeParseActions() {
		(0...31).forEach( { parseActions[$0] = parseNonPrinting })
		parseActions[127] = parseNonPrinting
	}

	private func setInitialParseState() {
		parseState = config.allowsComments ? .look4comment : .normal
	}

	// MARK: - Parse Functions -

	private func parseCR() {
		LOG("parseCR")
		composer.backSpace()
	}

	private func parseQuoteFirst() {
		LOG("parseQuoteFirst")
		do {
			// if we find anything other than tabs and spaces between last position and the first quote, hard _streamError
			try composer.resetBuffer()
			quoteCount += 1
			//LOG("  BUMP QUOTE COUNT \(quoteCount)")
			parseState = .quoteInsideString
		} catch {
			sendError(error)
		}
	}

	private func parseQuoteLatter() {
		LOG("parseQuoteLatter")
		quoteCount += 1
		//LOG("  BUMP QUOTE COUNT \(quoteCount)")
		let possibleEndQuote = quoteCount & 1 == 0
		parseState = possibleEndQuote ? .quoteLookAtNextChar : .quoteInsideString
		composer.ignoreAppend = possibleEndQuote
	}

	private func parseQuoteSecond() {
		LOG("parseQuoteSecond")
		composer.ignoreAppend = false
		composer.append(c: ASCII.quote.rawValue)
		quoteCount += 1
		//LOG("  BUMP QUOTE COUNT \(quoteCount)")
		parseState = .quoteInsideString
	}

	private func parseSpaceAfterClosingQuote() {
		LOG("parseSpaceAfterClosingQuote")
		parseState = .quoteLookForEnd
	}

	private func parseDelimiter() {
		LOG("parseDelimiter")
		//LOG("  QUOTE COUNT \(quoteCount)")

		let quotesMatch = quoteCount % 2 == 0
		guard quotesMatch else {
			let err = CSVbuildError(code: .quoteMissCount, description: "incorrect number of quotes on \(recordCount) <field>")
			sendError(err)
			return
		}

		if fieldNumber == 0 {
			traditionalDelegate?.csvParserDidBeginLine(recordNumber: recordCount)
		}

		if parseState == .normal && config.removeWhiteSpace {
			composer.removeTrailingSpace()
		}

		// normal processing, not a quoted string: '",,"' or ',"",'
		do {
			let s = try composer.field(emptyStringForNil: parseState != .normal)
			_streamStatus = .writing

			if let traditionalDelegate = traditionalDelegate {
				traditionalDelegate.csvParserDidReadField(field: s, atIndex: fieldNumber)
			}
			//LOG("FIELD: >\(s ?? "<null>")<")
			fields.append(s)
			fieldNumber += 1

			composer.ignoreAppend = false
			//LOG("  RESET QUOTE COUNT 1")
			quoteCount = 0
			setInitialParseState()
		} catch {
			sendError(error)
		}
	}

	private func parseNL() {
		LOG("parseNL")
		guard _streamStatus != .atEnd else { return }
//print("field", fieldNumber, "NUM", numFields)
		if numFields == 0 || fieldNumber == 0 || fieldNumber == (numFields - 1) {
			if fieldNumber == 0 && composer.isEmpty {
				_streamStatus = .atEnd
//print("SET TO ,atENd")
				_streamDelegate?.stream?(self, handle: .endEncountered)
				traditionalDelegate?.csvParserDidEndDocument()
				composer.ignoreAppend = true
				return
			}
			let _ = parseDelimiter()
			endLine()

			if !fields.isEmpty {
				// MUST be after endLine() is called. traditional delegate may have drained the fields via currentFields
				records.append(fields)
				fields.removeAll()
			}
			// Don't think this is worthwhile (and its odd from an OutputStream. After every write, you can get the decoded objects
			//_streamDelegate?.stream?(self, handle: .hasBytesAvailable)

			beginLine()
		} else {
			let err = CSVbuildError(code: .notEnoughFields, description: "not enought fields at line \(recordCount)")
			sendError(err)
		}
		setInitialParseState()
	}

	private func parseNonPrinting() {
		let err = CSVbuildError(code: .nonPrintingChar, description: "not enought fields at line \(recordCount)")
		sendError(err)
	}

	private func parseNumber() {
		// first character was '#', so eat rest of line
		parseState = .insideComment
	}

	private func parseCommentNL() {
		parseState = .look4comment
	}

	private func isWhiteSpace(_ c: UInt8) -> Bool {
		return c != ASCII.space.rawValue && c != ASCII.tab.rawValue
	}

	// Mark: - State Machine Functions -

	private func processNotNumberChar(c: UInt8) {
		assert(parseState == .look4comment)
		parseState = .normal
		processOneChar(c)
	}

	private func processNormalChar(c: UInt8) {
		LOG("processChar append \(Character( UnicodeScalar(c) ))")
		composer.append(c: c)
	}

	private func processPostQuotedStringIllegalChar(c: UInt8) {
		LOG("BAD CHAR \(Character( UnicodeScalar(c) ))")
		let err = CSVbuildError(code: .extraneousChars, description: #"found extraneous character after a quote: "\(c)""#)
		sendError(err)
// NOTE: remove these
//		processChar = processNormalChar
//		processChar(c)
	}

	// At start of a field, used when option to eat white space is on
	private func processEatWhiteSpaceChar(c: UInt8) {
		guard isWhiteSpace(c) else { return }	// find first non-white space char
		processChar = processNormalChar
		processChar(c)
	}

	private func processIgnoreChar(c: UInt8) { }

	private func processCharacters(buffer: UnsafeBufferPointer<UInt8>) -> Int {
		guard _streamError == nil else { print("STREAM ERROR GOT CHARS"); return 0 }
		LOG("processCharacters count =", buffer.count)
		buffer.forEach({ processOneChar($0) })
		return buffer.count
	}
	private func processOneChar(_ c: UInt8) {
		LOG("process", Character( UnicodeScalar(c)))
		if let action = parseActions[c] {
			LOG("processChar ACTION")
			action()
		} else {
			processChar(c)
		}
	}

	private func sendError(_ _error: Error) {
		let error = _error as NSError
		traditionalDelegate.csvParserDidFail(error: error)

		_streamStatus = .error
		_streamError = error
		_streamDelegate?.stream?(self, handle: .errorOccurred)
		parseState = .error
	}

	// MARK: - Utility -

	private func beginLine() {
		LOG("beginLine")
		// Don't send startLine because we could be at the end of the stream
		fieldNumber = 0;
		//LOG("  RESET QUOTE COUNT 0")
		quoteCount = 0
		composer.ignoreAppend = false
	}

	private func endLine() {
		LOG("endLine")
		let quotesMatch = quoteCount % 2 == 0
		guard quotesMatch else {
			let err = CSVbuildError(code: .quoteMissCount, description: "incorrect number of quotes on \(recordCount) <line>")
			sendError(err)
			return
		}
		defer { recordCount += 1 }

		traditionalDelegate?.csvParserDidEndLine(recordNumber: recordCount)

		if recordCount == 0 {
			numFields = fieldNumber
			//LOG("NUMFIELDS", numFields)

			if _streamDelegate != nil {
				if config.hasHeader {
					headers = fields.map({ $0 ?? "" })
				} else {
					headers = (0..<fieldNumber).map({ String($0) })
				}

				do {
					csvDecoder = try CSVDecoder(defaults: defaults!, headers: headers)
				} catch {
					sendError(error)
					return
				}
				if config.hasHeader {
					return
				}
			}

		} else {
			if numFields != fieldNumber {
				let err = CSVbuildError(code: .incorrectFieldCount, description: "incorrect number of fields: found \(fieldNumber) but expected \(numFields)")
				sendError(err)
				return
			}
		}

		if let csvDecoder = csvDecoder {
			var fieldsDictionary: [String: String?] = [:]
			csvDecoder.userFieldNames.enumerated().forEach( { fieldsDictionary[$1] = fields[$0]  })
			if let recordScrubber = recordScrubber{
				fieldsDictionary = recordScrubber(fieldsDictionary)
			}
			do {
				let record = recordCount - (config.hasHeader ? 1 : 0)
				let obj = try csvDecoder.decode(record: record , from: fieldsDictionary)
				decodedObjs.append(obj)
				//_streamDelegate?.stream?(self, handle: .hasBytesAvailable)
			} catch {
				sendError(error)
				return
			}
		}
	}

	private func EOF() {
		parseNL()
		guard _streamStatus == .writing else { return }

		_streamStatus = .atEnd
		_streamDelegate?.stream?(self, handle: .endEncountered)
		traditionalDelegate?.csvParserDidEndDocument()
	}

}

extension CSVParser {

    public override var streamStatus: Stream.Status { print("READ STAT \(_streamStatus.rawValue)"); return _streamStatus }
    public override var streamError: Error? { return _streamError }

    public override func open() {
		initializeParseActions()

		setInitialParseState()
		_streamStatus = .open

		_streamDelegate?.stream?(self, handle: .openCompleted)
		traditionalDelegate?.csvParserDidBeginDocument()
    }

    public override func write(_ ptr: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
		let buffer = UnsafeBufferPointer<UInt8>(start: ptr, count: len)
		return processCharacters(buffer: buffer)
	}

    public override func close() {
		switch _streamStatus {
		case .atEnd, .closed:
			_streamStatus = .closed
			parseState = .closed
		case .open, .writing:
			EOF()
		default:
			break
		}
	}

    public override func property(forKey key: Stream.PropertyKey) -> Any? { return nil }
    public override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { return false 	}
    public override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    public override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    public override var hasSpaceAvailable: Bool { return true }
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
