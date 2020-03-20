//
//  Decoder.swift
//  CSVParserInSwift
//
//  Created by David Hoerl on 2/19/20.
//  Copyright © 2020 David Hoerl. All rights reserved.
//

import Foundation

//private protocol OptionalProtocol {}
//extension Optional: OptionalProtocol {}

public let recordNumberProperty	= "CSV_RECORD_NUM"			// make the default 0, but its ignored
public let defaultedProperties	= "CSV_DEFAULTED_FIELDS"	// will get a set of those property names that got a default

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
        //print("DEC:", items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
#endif
}

extension CSVDecode {
	// Inspired by https://stackoverflow.com/a/56644881
	static var boolFalseStrings: Set<String> { [ "0", "0.0", "false", "f", "no", "n", "disabled", "disable", "off" ] }

	// Why: https://forums.swift.org/t/passing-decodable-object-type-as-generic-parameter/13870
	static func CSVencoder<T: Encodable>(encoder: JSONEncoder, from: T) throws -> Data {
		do {
			let val = try encoder.encode(from)
			return val
		} catch {
			throw error
		}
	}

	static func CSVdecoder<T: Decodable>(decoder: JSONDecoder, from: Data) throws -> T {
		do {
			let val = try decoder.decode(T.self, from: from)
			return val
		} catch {
			throw error
		}
	}

}

private enum PropertyType: CustomStringConvertible {
	case string(String)
	case integer(Int64)
	case uinteger(UInt64)
	case float(Double)
	case bool(Bool)

	var description: String {
		switch self {
		case .string(let s):
			return "String: \(s)"
		case .integer(let x):
			return "Integer: \(x)"
		case .uinteger(let x):
			return "UInteger: \(x)"
		case .float(let f):
			return "Double: \(f)"
		case .bool(let b):
			return "Boolean: \(b)"
		}
	}
}

// Public so devs can experiment with it alone
public final class CSVDecoder {
	private let headers: [String]
	private let defaults: CSVDecode
	private var headerToProperty: [String: String]
	private var propertyToHeader: [String: String]
	private var propertyDefaults: [String: PropertyType] = [:]
	private var optionalProperties: Set<String> = []

	var userFieldNames: [String] { headers.map({ headerToProperty[$0]! }) }

	init(defaults: CSVDecode, headers: [String]) throws {
		self.defaults = defaults
		self.headers = headers
		do {
			// get the translation of column headers to internal property names
			let dict = type(of: defaults).csvCodingKeys
			propertyToHeader = dict
			var d: [String: String] = [:]
			dict.forEach( { (key, value) in d[value] = key })
			headerToProperty = d
		}

		do {
			// First part: try to encode the default to JSON..
			let jsonData = try defaults.encode()
			LOG("JSON", String(data: jsonData, encoding: .utf8) ?? "<NONE>")
			// Convert the JSON to an array of Key/Value pairs
			let dict = try convertToDictionary(data: jsonData)
			propertyDefaults = dict
			LOG("headerToProperty VALUES:", headerToProperty)
			LOG("propertyToHeader VALUES:", propertyToHeader)
			LOG("DEFAULT VALUES:", propertyDefaults)
			LOG("OPTIONALS:", optionalProperties)
		} catch {
			throw error
		}

		do {
			// Now discover which properties are optional, and thus don't really take a default
			let props = determineOptionalProperties(for: defaults)
			optionalProperties = props
		}
	}

	func decode(record: Int, from dict: [String: String?]) throws -> CSVDecode {
		let json = buildJSON(record: record, from: dict, optionals: optionalProperties)
		do {
			let obj = try _decode(json)
			return obj
		} catch {
			throw error
		}
	}
	private func _decode(_ json: String) throws -> CSVDecode {
		let data = json.data(using: .utf8)!
		do {
			let obj = try defaults.decode(from: data)
			return obj
		} catch {
			throw error
		}
	}

	private func buildJSON(record: Int, from dict: [String: String?], optionals: Set<String>) -> String {
		var defaultedProps: Set<String> = []
		var str = "{ \n"

		func valueToBool(_ str: String) -> String {
			let s = str.lowercased()
			return type(of: defaults).boolFalseStrings.contains(s) ? "false" : "true"
		}
		func addKey(_ key: String) {
			if str.count > 5 { str += ",\n" }
			str += "\"\(key)\": "
		}

		for (key, _val) in dict {
			guard let propDef = propertyDefaults[key] else { continue }

			if let val = _val {
				addKey(key)

				switch propDef {
				case .string:
					str += " \"\(val)\""
				case .integer:
					str += " \(val)"
				case .uinteger:
					str += " \(val)"
				case .float:
					str += " \(val)"
				case .bool:
					let decode = valueToBool(val)
					str += " \(decode)"
				}
			} else {
				// csv was nil. If not an optional property, then use its default value
				guard !optionals.contains(key) else { continue }
				defaultedProps.insert(key)
				addKey(key)

				switch propDef {
				case .string(let s):
					str += " \"\(s)\""
				case .integer(let x):
					str += " \(x)"
				case .uinteger(let x):
					str += " \(x)"
				case .float(let f):
					str += " \(f)"
				case .bool(let b):
					str += " \(b)"
				}
			}
		}

		if let key = headerToProperty[recordNumberProperty], dict[key] == nil {
			if str.count > 5 { str += ",\n" }
			str += "\"\(key)\":  \(record)"
		}

		if let key = headerToProperty[defaultedProperties], dict[key] == nil {
			if str.count > 5 { str += ",\n" }

			var s = "\"\(key)\": "
			if !defaultedProps.isEmpty {
				s += "[ "
				for (idx, prop) in defaultedProps.enumerated() {
					if idx > 0 { s += ", " }
					s += "\"\(prop)\""
				}
				s += " ]"
			} else {
				s += "null"
			}
			str += s
		}
		str += "\n}\n"
		return str
	}

	private func determineOptionalProperties(for obj: CSVDecode) -> Set<String> {
		// second value below is essentially a do-nothing just to uncomplicate code
		let recordProp = propertyToHeader[recordNumberProperty] ?? ""
		let defaultsProp = propertyToHeader[defaultedProperties] ?? ""
		let keys = headerToProperty.keys.compactMap({ $0 ==  recordProp || $0 == defaultsProp ? nil : $0 })

		var emptyDict: [String: String?] = [:]
		keys.forEach({ emptyDict[$0] = Optional<String>.none })	// force use of the default value to be used

		var test: Set<String> = []
		for key in keys {
			test.insert(key)
			do {
				let json = buildJSON(record: 0, from: emptyDict, optionals: test)
				let _ = try _decode(json)
			} catch {
				test.remove(key)
			}
		}
		//print("OPTIONAL PROPERTY SET:", test)
		return test

#if false	// Sign. Mirror may not be available in Release versions
		func isOptional(_ instance: Any) -> Bool {
			let mirror = Mirror(reflecting: instance)
			let style = mirror.displayStyle
			return style == .optional
		}

		var set: Set<String> = []

		let m = Mirror(reflecting: obj)
		//print("M:", m, m.children.count)
		for c in m.children {
			guard let key = c.label else { continue }
			print("C:", key, "Value:", c.value, "TYPE:", type(of: c.value))
//			if isOptional(c.value) {
//				set.insert(key)
//			}
			if type(of: c.value) is OptionalProtocol.Type {
				set.insert(key)
			}
			// Sigh. Have to patch defaults as JSON doesn't flag date values - they look like doubles
			if type(of: c.value).contains("Date"), let jsonType = propertyDefaults[key], case .double(let val) = jsonType {
				propertyDefaults[key] = .date(val)
			}
		}
		LOG("SET:", set)
		return set
#endif
	}

	private func convertToDictionary(data: Data) throws -> [String: PropertyType] {
		do {
			let _dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
			guard let dict = _dict else { fatalError() }

			var retDict: [String: PropertyType] = [:]
			for (key, value) in dict {
				//print("KEY:", key, "VALUE", value, "TYPE:", String(describing: type(of: value)))

				let type: PropertyType
				switch value {
				case let x as String:
					//print("String", x)
					type = .string(x)
				case let x as NSNumber:
					// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
					let cc = String(cString: x.objCType)
					//print("Number", x, "TYPE:", cc)
					switch cc {
					case "q", "i", "l", "s":
						type = .integer(x.int64Value)
					case "Q", "I", "L", "S":
						type = .uinteger(x.uint64Value)
					case "f", "d":
						type = .float(x.doubleValue)
					case "c", "B":	// NSNumber uses "c" for ObjC Bools - see note end of this class
						type = .bool(x.boolValue)
					default:
						fatalError()
					}
				default:
					fatalError()
				}
				retDict[key] = type
			}
			return retDict
		} catch {
			throw error
		}
	}

}

/*
	Note on NSNumbers holding Objc BOOLs:

		let nt = NSNumber(booleanLiteral: true)
		print("T", String(cString: nt.objCType))
		"T c"
		let nf = NSNumber(booleanLiteral: false)
		print("F", String(cString: nf.objCType))
		"F c"
*/
