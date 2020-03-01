# SAX-CSV-Parser
Process streaming CSV text using a robust and fully [RFC-4180](https://tools.ietf.org/pdf/rfc4180.pdf) compliant parser. The parser offers an Apple *OutputStream* interface face (meaning you *open* it, *write* data, receive delegate messages, then *close* and release it).

It supports two types of modes: a *traditional* delegate interface based on [*CHCSVParser*](https://github.com/davedelong/CHCSVParser)  (lots of messages), and a modern *Swifty* interface where it converts *CSV* records into *Codable* objects (structs or classes) you define.

# Features

* multiline strings (per the RFC)
* comment lines (beginning with "#")
* double quotes (") inside quoted text per the RFC
* a familiar delegate protocol introduced by [*CHCSVParser*](https://github.com/davedelong/CHCSVParser)
* a *Streams* based interface returning *Codable Structs* (for CSV with or without a header)
* final records with a single NL, two NLs, or that just terminate
* no-data (user doesn't select even one field on a web site, taps `Download`)
* single-field records, meaning the stream has no delimiters (user selects only one column on a web site)
* optionals: empty fields return *nil*
* *Table* and *State Machine* driven—no pointer arithmetic. Enable LOG messages to observe
* Any character can be the delimiter (defaults to ',')

In addition to RFC-4180, support for oddities mentioned in an [RFC referenced document](http://www.creativyst.com/Doc/Articles/CSV/CSV01.htm):

* optional white space trimming (always done before and after a quoted string per RFC )
* optional Excel-specific scrubbing of fields using the '**="0..."**' format

## Updates
* Feb 28 2020: version 0.1.5 - removed Mirror for property type detection, just use JSON
* Feb 27 2020: version 0.1.1 - feature complete, now adding unit tests
* Feb 24 2020: version 0.0.4 - traditional interface complete along with unit tests
* Feb 23 2020: added this Readme

# Interface
Both the *delegate* and *streams* interface provide an options struct: 

```
struct CSVConfiguration {
    let delimiter: Character    // normally "," or TAB
    let hasHeader: Bool         // used when using Codable to create structs
    let removeWhiteSpace: Bool  // cleanup sloppy coding
    let excelSpecial: Bool      // '=(0001234) hack to preserve leading zeros
    let allowsComments: Bool    // if '#'is the first character, then ignore that line

    init(delimiter: Character = ",", hasHeader: Bool = true, removeWhiteSpace: Bool = true, excelSpecial: Bool = false, allowsComments: Bool = false)) {
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.removeWhiteSpace = removeWhiteSpace
        self.excelSpecial = excelSpecial
        self.allowsComments = allowsComments
    }
}
```

Errors are returned as *NSErrors* using a code equaling one of these:

```
public enum CSVError: Int {
    case charsBeforeQuote = 100
    case notEnoughFields
    case quoteMissCount
    case incorrectFieldCount
    case extraneousChars
    case stringConstructionFailed
    case nonPrintingChar
}
```
The *localDescription* has more informative info. Once an error is detected the parser does no more work.

### Usage

1. Decide to use the standard configuration, or define your own
2. Create a parser: `(traditionalDelegate: CSVParserProtocol?, configuration: CSVConfiguration = CSVConfiguration())`
3. Send `open()`
4. Send data via `write(_: UnsafePointer<UInt8>, maxLength: Int)`
5. Send `close()`

You can assemble the parsed data using three ways
* use the delegate methods that supply fields one by one. In this case, when you get *endOfLine*, empty the fields array via `let _ = parser.currentFields()` to avoid wasting memory
* use the delegate method *endOfLine* to retrieve an array of the fields via *currentFields()* (which also deletes them internally)
* wait until all the CSV text is processed, then retrieve an array of records using *allRecords()*, where each record is an array of its fields

## Delegate Interface

Use this initializer to get a delegate based parser:
```
CSVParse(traditionalDelegate: CSVParserProtocol?, configuration: CSVConfiguration = CSVConfiguration())
```

The protocol:

```
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
```
Note that because of the extension, you only need provide a subset of the methods. Or, don't provide a delegate at all, and after closing the parser, query to see if an error ocurred, or if not, retrieve all the data as an array of records, each record is an array of fields:

## Codable Interface

The parser does as much as it can to assist in converting the free flowing CSV records into Codable objects. The objects must conform to the CSVDecode protocol:

```
protocol CSVDecode: Decodable {
    static var defaultValues: CSVDecode { get } // You create this and provide it on demand.
    static var csvCodingKeys: [String: String] { get }      All properties - JSON decoding requires it.
    static var boolFalseStrings: Set<String> { get } // lower case and/or numbers that constitute "false". Default is supplied.

    func encode() throws -> Data
    func decode(from: Data) throws -> CSVDecode
}
```

The *defaultValues* is an object you supply that contains default values that the parser uses when the CSV has an empty (nil) field. You need to provide values for *Optional* properties, but the value isn't used (it allows the package to determine the property's type).

The `csvCodingKeys` provides the translation from the CSV Stream header to the `CSVDecode` property. If you have boolean properties, then the boolFalseStrings String set contains those strings that would result in false. The default set is: `[ "0", "0.0", "false", "f", "no", "n", "disabled", "disable", "off" ] `, but is easily overridden. 

The two functions you provide support both encoding your object into JSON, and decoding it from JSON. Since an object *Type* cannot be put into a property in *Swift 5.2*, you need to actually stuff your object type into the JSON encode/decode calls. Let's look an example of a *CSVDecode struct*.



## Example
```
struct Foo  {
    let x: Bool
    let y: String?
    let z: Date
    let a: UUID
    let i: UInt

    var record: Int = 0    // optional
    var defaults: [String]?    // optional
}
extension Foo: Encodable, Decodable, CSVDecode {
    static var defaultValues: CSVDecode {
    // Optionals need a value, but won't actually get defaulted if the CSV returns nil
    return Foo(x: true, y: "Fooy", z: Date(), a: UUID(), i: 17)
    }

    static var csvCodingKeys: [String: String] { [
    // Property    CSV_Header_Name
       "x":        "xx",
       "y":        "yy",
       "z":        "zz",
       "a":        "aa",
       "i":        "ii",
       "record":    recordNumberProperty, // recordNumberProperty defined in the package
       "defaults":  defaultedProperties // defaultedProperties defined in the package
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
```

Struct *Foo* has five base properties of types that JSON can handle (I was surprised by UUID!). The last two properties are special, and are explained below. You would have a similar definition. Then, you need to include or extend Foo to meet the protocol. The *defaultValues* supplies values for empty CSV fields. The csvCodingKeys provide the translation from CSV that you expect to have a header of: `xx,yy,zz,aa,ii`. 

But, if the CSV has no header, then the package creates a default numeric header: `[0,1,2,3,4,5...]`, so your translation table would look like:
```
"x":    "0",
"y":    "1",
"z":    "2",
...
```

The optional *record* property will be set to the zero-based CSV record number (ignoring the header or comments), and the optional *defaults* array contains the property labels of fields where a default value was used (e.g. `["x", "i"]`)

The two methods allow you to customize the JSON encoding process, which supports customized date processing for *Date* fields. The default conversion uses the double *timeSinceReferenceDate*. 

Note that you can provide all the necessary code to support conversion in an extension, which should help if the base object is defined elsewhere.

## Usage

1. Create a parser: `CSVDecoder(streamDelegate: StreamDelegate, configuration: CSVConfiguration = CSVConfiguration(), defaults: CSVDecode, recordScrubber: CSVRecordScrubber? = nil)`
  * *streamDelegate* - you don't really need to implement any of the optional methods, as the record are saved in an array and can be retrieved at the end via allRecords()
  * *configuration* - the configuration value described above
  * *defaults* - in the example above, it would be *Foo.defaultValues*
  * *recordScrubber* - an optional block that receives an array of the record fields before coding for pre-processing, defined as `(_ currentValues: [String: String?]) -> [String: String?]`
2. Send *open()*
3. Supply data via *`write(_: UnsafePointer<UInt8>, maxLength: Int)`*
4. Send *close()*

Whenever a record is processed, the stream delegate gets a *hasBytesAvailable* message. You can then get the decoded objects via *currentObjects()*, or just wait until after you send *close()*. When you receive records from *currentObjects()*, those records are subsequently deleted by the parser.


# Tests
This package has a large suite of tests that supply a slew of edge cases, including everything mentioned in the *Features* section, Tests not only look at the returned fields/records, but also that every delegate method is sent in the appropriate sequence, and that all that should be sent are.

# Credits
Inspired by [CHCSVParser](https://github.com/davedelong/CHCSVParser) (c) 2014 Dave DeLong, from which the delegate methods were modeled.

# Futures
Will entertain feature additions, just create an Issue.

# Notes
<none yet>