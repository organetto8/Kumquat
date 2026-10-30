import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
#if canImport(Translation)
import Translation
#endif
@testable import KumquatCore

// MARK: - Helpers

/// Runs through `Executor` like a drop on the wheel; failures become test issues.
private func perform(_ operation: KumquatCore.Operation, _ inputs: [URL], _ parameters: [String: String] = [:], into directory: URL? = nil) async throws -> JobOutcome {
    let out = try directory ?? Fixtures.tempDirectory()
    let outcome = await Executor.run(JobRequest(operation: operation, inputs: inputs, parameters: parameters, destination: { _ in out })) { _ in }
    if let failure = outcome.failures.first { Issue.record("\(failure.file): \(failure.message)") }
    return outcome
}

/// The single file an operation produced.
private func produce(_ operation: KumquatCore.Operation, _ input: URL, _ parameters: [String: String] = [:]) async throws -> URL {
    try #require(try await perform(operation, [input], parameters).outputs.first)
}

/// The message of an operation that is expected to fail.
private func failure(_ operation: KumquatCore.Operation, _ inputs: [URL], _ parameters: [String: String] = [:]) async throws -> String {
    let out = try Fixtures.tempDirectory()
    let outcome = await Executor.run(JobRequest(operation: operation, inputs: inputs, parameters: parameters, destination: { _ in out })) { _ in }
    #expect(outcome.outputs.isEmpty)
    return try #require(outcome.failures.first?.message)
}

private func file(_ name: String, _ contents: String, in directory: URL? = nil) throws -> URL {
    let url = try (directory ?? Fixtures.tempDirectory()).appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

/// Same tree with every object's keys sorted (for formats that regroup keys, like TOML).
private func sortedKeys(_ value: DataValue) -> DataValue {
    switch value {
    case .array(let items): .array(items.map(sortedKeys))
    case .object(let members): .object(members.map { .init($0.key, sortedKeys($0.value)) }.sorted { $0.key < $1.key })
    default: value
    }
}

private func json(_ text: String) throws -> DataValue { try JSONReader.parse(text) }

// MARK: - Structured data

@Suite struct DataEngineTests {
    let sample = """
    {"name": "Kumquat", "count": "007", "flag": "true", "colon": "a: b", "hash": "x #y", "multi": "line1\\nline2\\n",
     "multiNoEnd": "a\\nb", "quote": "it's", "empty": "", "spaces": " padded ", "num": 3, "pi": 3.14, "neg": -2, "yes": true,
     "none": null, "list": [1, [2, 3], {"k": "v", "k2": [true, false]}], "obj": {}, "arr": [], "unicode": "città ☀︎",
     "dash": "- item", "tab": "a\\tb", "url": "http://example.com/a#b", "nested": {"deep": {"deeper": [{"a": 1}, {"b": null}]}}}
    """

    @Test func jsonYamlRoundTripIsExact() async throws {
        let source = try file("data.json", sample)
        let yaml = try await produce(.convert(.yaml), source)
        let back = try await produce(.convert(.json), yaml)
        #expect(try json(text(back)) == json(sample))
        let written = try text(yaml)
        #expect(written.contains("multi: |\n  line1\n  line2\n"))
        #expect(written.contains("count: '007'"))
    }

    @Test func yamlReaderHandlesTheCommonSyntax() throws {
        let yaml = """
        %YAML 1.2
        ---
        # config
        name: Kumquat
        version: 1.10
        count: 007
        enabled: true
        nothing: ~
        quoted: "line\\nbreak"
        single: 'it''s'
        url: http://example.com/a#b
        list:
          - one
          - two # comment
          - {a: 1, b: [x, "y, z"]}
        nested:
          - name: first
            tags: [a, b]
          - name: second
        sameIndent:
        - p
        - q
        literal: |
          line 1
            indented
        folded: >-
          folded
          text

          para
        defaults: &defaults
          colour: orange
        fruit:
          <<: *defaults
          size: small
        empty:
        plain: a long
          continued line
        ---
        second: document
        """
        let expected = try json("""
        {"name": "Kumquat", "version": 1.1, "count": "007", "enabled": true, "nothing": null, "quoted": "line\\nbreak",
         "single": "it's", "url": "http://example.com/a#b", "list": ["one", "two", {"a": 1, "b": ["x", "y, z"]}],
         "nested": [{"name": "first", "tags": ["a", "b"]}, {"name": "second"}], "sameIndent": ["p", "q"],
         "literal": "line 1\\n  indented\\n", "folded": "folded text\\npara", "defaults": {"colour": "orange"},
         "fruit": {"colour": "orange", "size": "small"}, "empty": null, "plain": "a long continued line"}
        """)
        #expect(try YAMLReader.parse(yaml) == expected)
        #expect(throws: DataSyntaxError.self) { try YAMLReader.parse("a: [1, 2") }
        #expect(throws: DataSyntaxError.self) { try YAMLReader.parse("- a\nb: 1") }
    }

    @Test func tomlReadsAndRoundTrips() async throws {
        let toml = """
        # comment
        title = "TOML \\"example\\""
        [owner]
        name = 'Tom'
        dob = 1979-05-27T07:32:00-08:00
        [database]
        ports = [ 8000, 8001,
          8002, ]  # trailing comma
        enabled = true
        temp = { cpu = 79.5, case = 72.0 }
        hex = 0xDEAD_BEEF
        big = 1_000
        [servers.alpha]
        ip = "10.0.0.1"
        [[products]]
        name = "Hammer"
        [[products]]
        name = "Nail"
        notes = \"\"\"
        Roses are red
        Violets are \\
            blue\"\"\"
        site."google.com" = true
        """
        let expected = try json("""
        {"title": "TOML \\"example\\"", "owner": {"name": "Tom", "dob": "1979-05-27T07:32:00-08:00"},
         "database": {"ports": [8000, 8001, 8002], "enabled": true, "temp": {"cpu": 79.5, "case": 72.0}, "hex": 3735928559, "big": 1000},
         "servers": {"alpha": {"ip": "10.0.0.1"}},
         "products": [{"name": "Hammer"}, {"name": "Nail", "notes": "Roses are red\\nViolets are blue", "site": {"google.com": true}}]}
        """)
        #expect(try TOMLReader.parse(toml) == expected)
        #expect(throws: DataSyntaxError.self) { try TOMLReader.parse("a = 1\na = 2") }

        let source = try file("config.json", """
        {"title": "Kumquat", "version": 2, "ratio": 0.5, "tags": ["a", "b"], "owner": {"name": "Ada", "langs": ["en", "it"]},
         "items": [{"id": 1, "name": "x"}, {"id": 2, "name": "y", "meta": {"ok": true}}], "matrix": [[1, 2], [3, 4]], "odd key": "q"}
        """)
        let written = try await produce(.convert(.toml), source)
        #expect(try text(written).contains("[[items]]"))
        let back = try await produce(.convert(.json), written)
        #expect(sortedKeys(try json(text(back))) == sortedKeys(try json(text(source))))
    }

    @Test func xmlUsesAttributeAndTextKeys() async throws {
        let source = try file("catalog.json", """
        {"catalog": {"@version": "1", "fruit": [{"@id": "k1", "name": "Kumquat", "price": "1.5"}, {"@id": "k2", "name": "Lime"}],
         "note": "Fresh & <tasty>", "label": {"@lang": "it", "#text": "Agrumi"}}}
        """)
        let xml = try await produce(.convert(.xml), source)
        let written = try text(xml)
        #expect(written.contains("<catalog version=\"1\">"))
        #expect(written.contains("<fruit id=\"k1\">"))
        #expect(written.contains("Fresh &amp; &lt;tasty&gt;"))
        let back = try await produce(.convert(.json), xml)
        #expect(try json(text(back)) == json(text(source)))
    }

    @Test func plistKeepsTypesAndOrder() async throws {
        let source = try file("settings.json", #"{"name": "Kumquat", "count": 3, "ratio": 0.5, "flag": true, "list": [1, "a"], "dict": {"b": 1, "a": 2}}"#)
        let plist = try await produce(.convert(.plist), source)
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        #expect(object?["count"] as? Int == 3)
        let back = try await produce(.convert(.json), plist)
        #expect(try json(text(back)) == json(text(source)))

        // Binary plists are read too (keys come back sorted).
        let dir = try Fixtures.tempDirectory()
        let binary = dir.appendingPathComponent("binary.plist")
        try PropertyListSerialization.data(fromPropertyList: ["z": 1, "a": [true, "x"]], format: .binary, options: 0).write(to: binary)
        let fromBinary = try await produce(.convert(.yaml), binary)
        #expect(try text(fromBinary) == "a:\n  - true\n  - x\nz: 1\n")
    }

    @Test func jsonBecomesTables() async throws {
        let source = try file("people.json", #"[{"name": "Ada", "tags": ["x", "y"], "age": 36}, {"name": "Bob", "city": "Rome"}]"#)
        let csv = try await produce(.convert(.csv), source)
        #expect(CSV.parse(try text(csv), delimiter: ",") == [["name", "tags", "age", "city"], ["Ada", #"["x","y"]"#, "36", ""], ["Bob", "", "", "Rome"]])
        let workbook = try file("groups.json", #"{"fruit": [{"n": "kumquat"}], "veg": [{"n": "leek"}, {"n": "kale"}]}"#)
        let xlsx = try await produce(.convert(.xlsx), workbook)
        let sheets = try await XLSX.read(xlsx)
        #expect(sheets.map(\.name) == ["fruit", "veg"])
        #expect(sheets[1].rows == [["n"], ["leek"], ["kale"]])
    }

    @Test func invalidInputExplainsWhere() async throws {
        let broken = try file("broken.json", "{\n  \"a\": 1,\n  \"b\": ]\n}")
        let message = try await failure(.convert(.yaml), [broken])
        #expect(message.contains("isn't valid JSON") && message.contains("line 3"))
    }

    @Test func sqliteTablesBothWays() async throws {
        let dir = try Fixtures.tempDirectory()
        let csv = try file("fruit.csv", "name,kg,origin\nkumquat,1.5,China\nlime,2,\"Mexico, south\"\n", in: dir)
        let db = try await produce(.convert(.sqlite), csv)
        let tables = try SQLiteFile.read(db)
        #expect(tables.map(\.name) == ["fruit"])
        #expect(tables[0].columns == ["name", "kg", "origin"])
        #expect(tables[0].rows[1] == [.string("lime"), .double(2), .string("Mexico, south")])

        let back = try await produce(.convert(.json), db)
        #expect(try json(text(back)) == json(#"{"fruit": [{"name": "kumquat", "kg": 1.5, "origin": "China"}, {"name": "lime", "kg": 2.0, "origin": "Mexico, south"}]}"#))
        let xlsx = try await produce(.convert(.xlsx), db)
        #expect(try await XLSX.read(xlsx).first?.rows.first == ["name", "kg", "origin"])
        let fromDB = try await produce(.convert(.csv), db)
        #expect(CSV.parse(try text(fromDB), delimiter: ",").count == 3)
    }

    @Test func contactsToSheetsAndBack() async throws {
        let vcf = try file("contacts.vcf", """
        BEGIN:VCARD\r
        VERSION:3.0\r
        N:Lovelace;Ada;;;\r
        FN:Ada Lovelace\r
        ORG:Analytical Engines;Research\r
        TEL;TYPE=CELL:+44 20 1234 5678\r
        item1.TEL;TYPE=WORK:+44 20 8765 4321\r
        EMAIL:ada@example.com\r
        ADR;TYPE=HOME:;;12 St James's Square;London;;SW1Y 4JH;UK\r
        BDAY:18151210\r
        NOTE:First programmer\\, really. A long note that keeps going so that the line has to be fol\r
         ded by the writer.\r
        END:VCARD\r
        BEGIN:VCARD\r
        VERSION:2.1\r
        N:Babbage;Charles\r
        TEL;CELL:555-0100\r
        NOTE;ENCODING=QUOTED-PRINTABLE:Difference=20engine=\r
        =20one\r
        END:VCARD\r

        """)
        let csv = try await produce(.convert(.csv), vcf)
        let rows = CSV.parse(try text(csv), delimiter: ",")
        #expect(rows == [
            VCard.headers,
            ["Ada Lovelace", "Analytical Engines, Research", "+44 20 1234 5678; +44 20 8765 4321", "ada@example.com",
             "12 St James's Square, London, SW1Y 4JH, UK", "1815-12-10", "First programmer, really. A long note that keeps going so that the line has to be folded by the writer."],
            ["Charles Babbage", "", "555-0100", "", "", "", "Difference engine one"],
        ])
        // The sheet goes back to contacts with the same fields.
        let again = try await produce(.convert(.vcf), csv)
        #expect(VCard.rows(try text(again)) == rows)

        let italian = try file("rubrica.csv", "Nome,Cognome,Telefono,Cellulare,Email,Azienda,Compleanno\nMario,Rossi,06 1234567,333 1234567,mario@example.it,Acme,15/03/1980\n,,,,,,\n")
        let cards = try await produce(.convert(.vcf), italian)
        let written = try text(cards)
        #expect(written.contains("N:Rossi;Mario;;;\r\n"))
        #expect(VCard.rows(written) == [VCard.headers, ["Mario Rossi", "Acme", "06 1234567; 333 1234567", "mario@example.it", "", "1980-03-15", ""]])
    }

    @Test func calendarsToSheetsAndBack() async throws {
        let ics = try file("orchard.ics", """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Harvest\\, kumquats
        DTSTART;VALUE=DATE:20240115
        DTEND;VALUE=DATE:20240117
        LOCATION:Orchard
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Market
        DTSTART:20240120T090000
        DURATION:PT2H30M
        DESCRIPTION:Sell the crop
        BEGIN:VALARM
        TRIGGER:-PT15M
        DESCRIPTION:Reminder
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """)
        let csv = try await produce(.convert(.csv), ics)
        #expect(CSV.parse(try text(csv), delimiter: ",") == [
            ICal.headers,
            ["Harvest, kumquats", "2024-01-15", "2024-01-16", "Orchard", "", "yes"],
            ["Market", "2024-01-20 09:00", "2024-01-20 11:30", "", "Sell the crop", "no"],
        ])

        let italian = try file("agenda.csv", "Titolo,Inizio,Fine,Luogo,Descrizione\nRaccolta,15/03/2024,,Frutteto,\nMercato,20/03/2024 09:30,20/03/2024 11:00,Piazza,Banco 4\n")
        let events = try await produce(.convert(.ics), italian)
        let written = try text(events)
        #expect(written.hasPrefix("BEGIN:VCALENDAR\r\n") && written.contains("DTSTART;VALUE=DATE:20240315\r\nDTEND;VALUE=DATE:20240316\r\n"))
        #expect(ICal.rows(written) == [
            ICal.headers,
            ["Raccolta", "2024-03-15", "2024-03-15", "Frutteto", "", "yes"],
            ["Mercato", "2024-03-20 09:30", "2024-03-20 11:00", "Piazza", "Banco 4", "no"],
        ])
        let noDates = try file("names.csv", "Name\nAda\n")
        #expect(try await failure(.convert(.ics), [noDates]).contains("Start"))
    }
}

// MARK: - Spreadsheets

@Suite struct SheetToolTests {
    let csv = "name,city,kg\nAda,Rome,1.5\nBob,Milan,2\nCy,Rome,3\nAda,Rome,1.5\n"

    @Test func newTargets() async throws {
        let source = try file("fruit.csv", csv)
        let records = try json(text(try await produce(.convert(.json), source)))
        #expect(records == (try json(#"[{"name": "Ada", "city": "Rome", "kg": 1.5}, {"name": "Bob", "city": "Milan", "kg": 2}, {"name": "Cy", "city": "Rome", "kg": 3}, {"name": "Ada", "city": "Rome", "kg": 1.5}]"#)))
        let markdown = try text(try await produce(.convert(.md), source))
        #expect(markdown.hasPrefix("| name | city | kg |\n| --- | --- | ---: |\n| Ada | Rome | 1.5 |"))
        let html = try text(try await produce(.convert(.html), source))
        #expect(html.contains("<th>name</th>") && html.contains("<td class=\"n\">1.5</td>"))

        let xlsx = try Fixtures.tempDirectory().appendingPathComponent("book.xlsx")
        try XLSX.write([Sheet(name: "A", rows: [["x"], ["1"]]), Sheet(name: "B", rows: [["y"], ["true"]])], to: xlsx)
        #expect(try json(text(try await produce(.convert(.json), xlsx))) == (try json(#"{"A": [{"x": 1}], "B": [{"y": true}]}"#)))
    }

    @Test func tools() async throws {
        let dir = try Fixtures.tempDirectory()
        let source = try file("fruit.csv", csv, in: dir)

        let parts = try await perform(.tool(.split), [source], ["by": "column", "column": "city"], into: try Fixtures.tempDirectory()).outputs
        #expect(parts.map(\.lastPathComponent) == ["fruit – Rome.csv", "fruit – Milan.csv"])
        #expect(CSV.parse(try text(parts[0]), delimiter: ",").count == 4)
        #expect(try await failure(.tool(.split), [source], ["by": "column", "column": "nope"]).contains("nope"))

        let excel = try await produce(.tool(.csvExcel), source)
        let bytes = try Data(contentsOf: excel)
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self).hasPrefix("name;city;kg\r\nAda;Rome;1,5\r\n"))

        let deduped = try await perform(.tool(.dedupe), [source])
        #expect(deduped.notes.first == "1 duplicate rows removed")
        #expect(CSV.parse(try text(try #require(deduped.outputs.first)), delimiter: ",").count == 4)
        let byCity = try await perform(.tool(.dedupe), [source], ["column": "B"])
        #expect(byCity.notes.first == "2 duplicate rows removed")

        let stats = try text(try await produce(.tool(.columnStats), source))
        #expect(stats.contains("4 rows · 3 columns"))
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        #expect(stats.contains("| kg | Number | 0 | 3 | \(number(1.5)) | \(number(3)) | \(number(2)) |"))
        #expect(stats.contains("| city | Text | 0 | 2 |"))

        let transposed = try await produce(.tool(.transpose), source)
        #expect(CSV.parse(try text(transposed), delimiter: ",").first == ["name", "Ada", "Bob", "Cy", "Ada"])
    }
}

// MARK: - Subtitles

@Suite struct SubtitleFormatTests {
    let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello <i>there</i>\n\n2\n00:01:00,250 --> 00:01:03,000\nSecond line\nand more\n"

    @Test(arguments: [FileFormat.vtt, .ass, .sbv, .ttml, .lrc])
    func roundTripsThrough(format: FileFormat) async throws {
        let source = try file("movie.srt", srt)
        let converted = try await produce(.convert(format), source)
        #expect(converted.pathExtension == format.fileExtension)
        #expect(SubtitleEngine.sniff(try text(converted)) == format)
        let back = try await produce(.convert(.srt), converted)
        let original = SubtitleEngine.parse(srt), cues = SubtitleEngine.parse(try text(back))
        try #require(cues.count == original.count)
        for (cue, expected) in zip(cues, original) {
            #expect(abs(cue.start - expected.start) < 0.011 && abs(cue.end - expected.end) < 0.011)
        }
        switch format {
        case .vtt, .ass, .ttml: #expect(cues.map(\.text) == original.map(\.text))
        case .lrc: #expect(cues.map(\.text) == ["Hello there", "Second line and more"])
        default: #expect(cues.map(\.text) == ["Hello there", "Second line\nand more"])
        }
    }

    @Test func readsForeignFiles() throws {
        let ass = """
        [Script Info]
        Title: Test

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,ignored
        Dialogue: 0,0:00:02.50,0:00:04.00,Default,,0,0,0,,{\\an8}{\\i1}Up top{\\i0}, with a comma\\Nsecond
        """
        #expect(SubtitleEngine.parse(ass) == [Cue(start: 2.5, end: 4, text: "<i>Up top</i>, with a comma\nsecond")])
        let dfxp = """
        <?xml version="1.0"?>
        <tt xmlns="http://www.w3.org/2006/10/ttaf1" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" ttp:tickRate="10000000">
        <body><div><p begin="10000000t" end="25000000t">One<br/>
           two</p><p begin="3s" dur="1.5s">Three</p></div></body></tt>
        """
        #expect(SubtitleEngine.parse(dfxp) == [Cue(start: 1, end: 2.5, text: "One\ntwo"), Cue(start: 3, end: 4.5, text: "Three")])
        let lrc = "[ar:Someone]\n[offset:+500]\n[00:01.50][00:10.00]Chorus\n[00:05.00]Verse\n[00:08.00]\n"
        #expect(SubtitleEngine.parse(lrc) == [Cue(start: 1, end: 4.5, text: "Chorus"), Cue(start: 4.5, end: 7.5, text: "Verse"),
                                              Cue(start: 9.5, end: 13.5, text: "Chorus")])
    }

    @Test func frameRateAndClean() async throws {
        let source = try file("film.srt", """
        1
        00:00:25,000 --> 00:00:26,000
        JOHN: Hello (laughs) <i>there</i>

        2
        00:00:30,000 --> 00:00:31,000
        [MUSIC PLAYING]

        3
        00:00:32,000 --> 00:00:33,000
        - MARY: Fine.
        - Note: this stays.

        """)
        let rescaled = SubtitleEngine.parse(try text(try await produce(.tool(.changeFPS), source, ["from": "23.976", "to": "25"])))
        #expect(abs(rescaled[0].start - 23.976) < 0.001)
        let cleaned = SubtitleEngine.parse(try text(try await produce(.tool(.clean), source)))
        #expect(cleaned.map(\.text) == ["Hello there", "- Fine.\n- Note: this stays."])
        #expect(cleaned[1].start == 32)
    }
}

// MARK: - Documents

@Suite struct DocumentFormatTests {
    let markdown = """
    Opening words.

    # Kumquat Report

    Kumquats are **tiny** citrus fruits. See [site](https://example.com).

    - Grows in pots
    - Loves sun

    ## Care

    Water weekly.

    # Harvest

    Pick in winter.
    """

    @Test func richTextTargets() async throws {
        let source = try file("report.md", markdown)
        for (format, type) in [(FileFormat.rtf, NSAttributedString.DocumentType.rtf), (.doc, .docFormat), (.odt, .openDocument)] {
            let output = try await produce(.convert(format), source)
            #expect(output.pathExtension == format.fileExtension)
            let loaded = try NSAttributedString(url: output, options: [.documentType: type], documentAttributes: nil)
            #expect(loaded.string.contains("Loves sun"), "\(format)")
        }
    }

    @Test(.enabled(if: Engines.pandoc != nil)) func markupThroughPandoc() async throws {
        let source = try file("report.md", markdown)
        let tex = try text(try await produce(.convert(.tex), source))
        #expect(tex.contains("\\documentclass") && tex.contains("\\section{Kumquat Report}") && tex.contains("\\textbf{tiny}"))
        #expect(try text(try await produce(.convert(.rst), source)).contains("Kumquat Report\n=============="))
        #expect(try text(try await produce(.convert(.org), source)).contains("* Kumquat Report"))
        #expect(try text(try await produce(.convert(.adoc), source)).contains("Kumquat Report"))

        let latex = try file("paper.tex", "\\documentclass{article}\\begin{document}\\section{Intro}Hello \\textbf{world}.\\end{document}")
        let md = try text(try await produce(.convert(.md), latex))
        #expect(md.contains("# Intro") && md.contains("**world**"))
        let model = try await DocumentEngine.model(latex, format: .tex)
        #expect(model.blocks.first == .heading(1, [Inline(text: "Intro")]))
        let pdf = try await produce(.convert(.pdf), latex)
        #expect(PDFDocument(url: pdf)?.string?.contains("Hello") == true)

        let rst = try file("notes.rst", "Title\n=====\n\nHello *there*.\n")
        let docx = try await produce(.convert(.docx), rst)
        #expect(try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string.contains("Hello there"))
        let org = try file("todo.org", "* Heading\nSome /text/.\n")
        #expect(try text(try await produce(.convert(.html), org)).contains("<h1"))
        // Formats pandoc can't read go through AppKit first.
        let txt = try file("plain.txt", "Just *text* & more\n")
        #expect(try text(try await produce(.convert(.rst), txt)).contains("Just \\*text\\* & more"))
        let rtf = try file("letter.rtf", #"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs24 Dear reader,\par Kumquats ripen.}"#)
        #expect(try text(try await produce(.convert(.org), rtf)).contains("Kumquats ripen."))
    }

    @Test(.enabled(if: Engines.ebookConvert != nil)) func ebooksThroughCalibre() async throws {
        let source = try file("book.md", markdown)
        let mobi = try await produce(.convert(.mobi), source)
        #expect(size(mobi) > 0)
        let epub = try await produce(.convert(.epub), mobi)
        let back = try await DocumentEngine.model(epub, format: .epub)
        #expect(back.blocks.contains { if case .heading(_, let inlines) = $0 { inlines.plainText == "Harvest" } else { false } })
        #expect(try text(try await produce(.convert(.html), mobi)).contains("Harvest"))
    }

    @Test func splitAtHeadings() async throws {
        let source = try file("report.md", markdown)
        let chapters = try await perform(.tool(.split), [source]).outputs
        #expect(chapters.map(\.lastPathComponent) == ["00 report.md", "01 Kumquat Report.md", "02 Harvest.md"])
        #expect(try text(chapters[1]).hasPrefix("# Kumquat Report\n") && text(chapters[1]).contains("## Care"))
        #expect(try await perform(.tool(.split), [source], ["level": "2"]).outputs.count == 4)

        let docx = try await produce(.convert(.docx), source)
        let parts = try await perform(.tool(.split), [docx]).outputs
        #expect(parts.map(\.lastPathComponent) == ["00 report.docx", "01 Kumquat Report.docx", "02 Harvest.docx"])
        #expect(try NSAttributedString(url: parts[2], options: [:], documentAttributes: nil).string.contains("Pick in winter"))

        let txt = try file("novel.txt", "Preface.\n\nCHAPTER ONE\n\nIt was cold.\n\nChapter 2\n\nIt was warm.\n")
        #expect(try await perform(.tool(.split), [txt]).outputs.map(\.lastPathComponent) == ["00 novel.txt", "01 CHAPTER ONE.txt", "02 Chapter 2.txt"])
        let html = try file("page.html", "<html><body><h1>One</h1><p>A</p><h1>Two</h1><p>B</p></body></html>")
        let pages = try await perform(.tool(.split), [html]).outputs
        #expect(try pages.count == 2 && text(pages[1]).contains("<p>B</p>"))
        let flat = try file("flat.md", "No headings here.\n")
        #expect(try await failure(.tool(.split), [flat]).contains("no headings"))
    }

    @Test func findAndReplace() async throws {
        let txt = try file("notes.txt", "kumquat Kumquat kumquat, 12 kg and 3 kg\n")
        let replaced = try await perform(.tool(.findReplace), [txt], ["find": "kumquat", "replace": "lime"])
        #expect(replaced.notes.first == "2 replacements")
        #expect(try text(try #require(replaced.outputs.first)) == "lime Kumquat lime, 12 kg and 3 kg\n")
        let regex = try await produce(.tool(.findReplace), txt, ["find": #"(\d+) kg"#, "replace": "$1 kilograms", "regex": "regex"])
        #expect(try text(regex).contains("12 kilograms and 3 kilograms"))
        #expect(try await failure(.tool(.findReplace), [txt], ["find": "orange"]).contains("No matches"))
        #expect(try await failure(.tool(.findReplace), [txt], ["find": "(", "regex": "regex"]).contains("regular expression"))

        let html = try file("page.html", #"<p class="kumquat">A kumquat</p><script>var kumquat = 1;</script>"#)
        #expect(try text(try await produce(.tool(.findReplace), html, ["find": "kumquat", "replace": "lime"])) == #"<p class="kumquat">A lime</p><script>var kumquat = 1;</script>"#)

        // In Word the match spans two differently formatted runs.
        let dir = try Fixtures.tempDirectory()
        let docx = dir.appendingPathComponent("letter.docx")
        let body = NSMutableAttributedString(string: "Hello ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        body.append(NSAttributedString(string: "wor", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        body.append(NSAttributedString(string: "ld & world", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        try DocumentEngine.write(body, type: .officeOpenXML, to: docx)
        let word = try await perform(.tool(.findReplace), [docx], ["find": "world", "replace": "<planet>"])
        #expect(word.notes.first == "2 replacements")
        let edited = try NSAttributedString(url: try #require(word.outputs.first), options: [:], documentAttributes: nil)
        #expect(edited.string.contains("Hello <planet> & <planet>"))

        let rtf = try file("letter.rtf", #"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\fs24 Dear reader,\par Kumquats ripen in {\b winter}.}"#)
        let rtfOut = try await produce(.tool(.findReplace), rtf, ["find": "winter", "replace": "January"])
        #expect(try NSAttributedString(url: rtfOut, options: [:], documentAttributes: nil).string.contains("ripen in January"))
    }

    @Test func cleanText() async throws {
        let messy = "\u{FEFF}# Title  \r\n\r\n\r\n\r\nSome  doubled   spaces.\t\r\nLine with break  \r\nnext\r\n\r\n```\r\ncode    stays\r\n```\r\n| a  | b  |\r\n\r\n\r\n"
        let source = try file("messy.md", messy)
        #expect(try text(try await produce(.tool(.clean), source)) == "# Title\n\nSome doubled spaces.\nLine with break\\\nnext\n\n```\ncode    stays\n```\n| a  | b  |\n")
    }

    @Test func compressOfficePictures() async throws {
        let dir = try Fixtures.tempDirectory()
        let plain = dir.appendingPathComponent("plain.docx")
        try DocumentEngine.write(NSAttributedString(string: "Kumquats in the picture."), type: .officeOpenXML, to: plain)
        #expect(try await failure(.tool(.compress), [plain]).contains("no pictures"))

        let root = try await PackageReader.extract(plain)
        let media = root.appendingPathComponent("word/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Fixtures.write(Fixtures.makeImage(width: 4000, height: 3000), to: media.appendingPathComponent("image1.jpeg"), type: .jpeg,
                           properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let heavy = dir.appendingPathComponent("heavy.docx")
        try OfficePackage.zip(root, to: heavy)

        let compressed = try await produce(.tool(.compress), heavy, ["quality": "60"])
        #expect(compressed.lastPathComponent == "heavy (compressed).docx")
        #expect(size(compressed) < size(heavy))
        let entries = try Data(contentsOf: compressed)
        #expect(String(decoding: entries[30..<(30 + 19)], as: UTF8.self) == "[Content_Types].xml")
        #expect(try NSAttributedString(url: compressed, options: [:], documentAttributes: nil).string.contains("Kumquats in the picture"))
        let unpacked = try await PackageReader.extract(compressed)
        #expect(ImageProbe.orientedPixelSize(unpacked.appendingPathComponent("word/media/image1.jpeg")) == CGSize(width: 2560, height: 1920))
    }

    @Test func speakerNotesAndMedia() async throws {
        let dir = try Fixtures.tempDirectory()
        let pptx = dir.appendingPathComponent("talk.pptx")
        let p = #"xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        func shape(_ type: String, _ paragraphs: [String]) -> String {
            #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="x"/><p:cNvSpPr/><p:nvPr><p:ph type="\#(type)"/></p:nvPr></p:nvSpPr><p:txBody>"#
                + paragraphs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined() + "</p:txBody></p:sp>"
        }
        func slide(_ title: String) -> String { "<p:sld \(p)><p:cSld><p:spTree>\(shape("title", [title]))</p:spTree></p:cSld></p:sld>" }
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        zip.add("ppt/presentation.xml", #"<p:presentation \#(p)><p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>"#)
        zip.add("ppt/_rels/presentation.xml.rels", #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="\#(rel)/slide" Target="slides/slide2.xml"/><Relationship Id="rId3" Type="\#(rel)/slide" Target="slides/slide1.xml"/></Relationships>"#)
        zip.add("ppt/slides/slide1.xml", slide("Welcome"))
        zip.add("ppt/slides/slide2.xml", slide("Prices"))
        zip.add("ppt/slides/_rels/slide1.xml.rels", #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>"#)
        zip.add("ppt/notesSlides/notesSlide1.xml", "<p:notes \(p)><p:cSld><p:spTree>\(shape("sldImg", []))\(shape("body", ["Say hello.", "Smile."]))\(shape("sldNum", ["1"]))</p:spTree></p:cSld></p:notes>")
        let png = dir.appendingPathComponent("image1.png")
        try Fixtures.write(Fixtures.makeImage(width: 20, height: 10), to: png, type: .png)
        zip.add("ppt/media/image1.png", try Data(contentsOf: png))
        try zip.write(to: pptx)

        let outputs = try await perform(.tool(.extractNotes), [pptx]).outputs
        #expect(outputs.map(\.lastPathComponent) == ["talk notes.txt", "image1.png"])
        #expect(try text(outputs[0]) == "Slide 1: Welcome\nSay hello.\nSmile.\n\nSlide 2: Prices\n")
        #expect(outputs[0].deletingLastPathComponent().lastPathComponent == "talk notes and media")
    }
}

// MARK: - Language

@Suite struct LanguageEngineTests {
    @Test func wordCounts() async throws {
        let txt = try file("notes.txt", "Kumquats are tiny citrus fruits.\nThey taste sweet.\n")
        let count = try #require(try await perform(.tool(.wordCount), [txt]).notes.first)
        #expect(count.hasPrefix("8 words · ") && count.hasSuffix("1 min read"))
        #expect(count.contains("49 characters"))

        let dir = try Fixtures.tempDirectory()
        let pdf = dir.appendingPathComponent("pages.pdf")
        Fixtures.makePDF(pages: 2, to: pdf)
        let pdfCount = try #require(try await perform(.tool(.wordCount), [pdf]).notes.first)
        #expect(pdfCount.hasPrefix("6 words"))
        let markdown = try file("styled.md", "# Title\n\n**Bold** and *soft* words.\n")
        #expect(try await perform(.tool(.wordCount), [markdown]).notes.first?.hasPrefix("5 words") == true)
    }

    @Test func chunksStayWithinTheLimit() {
        let text = (1...40).map { "Paragraph \($0) has a few words in it. And a second sentence." }.joined(separator: "\n\n")
        let pieces = LanguageEngine.chunks(text, limit: 300)
        #expect(pieces.count > 1 && pieces.allSatisfy { $0.count <= 300 })
        #expect(pieces.joined(separator: "\n\n") == text)
    }

    @Test func translateWhenTheLanguagesAreInstalled() async throws {
        #if canImport(Translation)
        guard #available(macOS 26.0, *) else { return }
        let dir = try Fixtures.tempDirectory()
        let txt = try file("notes.txt", "The orchard is full of ripe kumquats.\n\nWe pick them every winter morning before breakfast.\n", in: dir)
        switch await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "it")) {
        case .installed:
            let translated = try text(try await produce(.tool(.translate), txt, ["language": "it"]))
            #expect(translated.components(separatedBy: "\n\n").count == 3)
            #expect(!translated.contains("orchard"))
            let srt = try file("movie.srt", "1\n00:00:01,000 --> 00:00:02,500\nGood morning, my friend.\n", in: dir)
            let subtitles = SubtitleEngine.parse(try text(try await produce(.tool(.translate), srt, ["language": "it"])))
            #expect(subtitles.count == 1 && subtitles[0].start == 1 && subtitles[0].end == 2.5 && subtitles[0].text != "Good morning, my friend.")
        case .supported:
            #expect(try await failure(.tool(.translate), [txt], ["language": "it"]).contains("System Settings"))
        default:
            break
        }
        #endif
    }

    @Test func summarizeWhenAppleIntelligenceIsOn() async throws {
        let txt = try file("report.txt", """
        Kumquats are small citrus fruits that grow on evergreen trees. They are eaten whole, peel included, \
        because the peel is sweet while the flesh is tart. The trees tolerate cold better than most citrus.

        Growers harvest kumquats in winter. The fruit is used for marmalade, candied as a snack, or sliced into salads.
        """)
        guard let reason = LanguageEngine.summaryUnavailableReason else {
            let summary = try text(try await produce(.tool(.summarize), txt))
            #expect(summary.hasPrefix("# Summary of “report”\n\n"))
            #expect(summary.count > 40)
            return
        }
        #expect(try await failure(.tool(.summarize), [txt]) == reason)
    }
}
