import Foundation
@testable import HablaCore

/// Builds small EPUBs in memory with the quirks real books have.
enum Fixtures {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("habla-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func xhtml(_ body: String, bodyType: String? = nil) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>t</title><style>p { margin: 0 }</style></head>
        <body\(bodyType.map { " epub:type=\"\($0)\"" } ?? "")>\(body)</body></html>
        """
    }

    /// A small novel: copyright page, two chapters (one split across two files), nav TOC.
    static func sampleEPUB() -> Data {
        let files: [(String, String)] = [
            ("OEBPS/copyright.xhtml", xhtml("<section epub:type=\"copyright-page\"><p>Copyright &copy; 2024. All rights reserved.</p></section>", bodyType: "frontmatter")),
            ("OEBPS/ch1.xhtml", xhtml("""
                <section><h2>Chapter I</h2>
                <p>It was 1813, and Mr.&nbsp;Darcy was <em>not</em> amused.<a epub:type="noteref" href="#n1">1</a> He had $5 and 3 dogs.</p>
                <p>“Do you want to know?” cried his wife.</p>
                <hr/>
                <p>* * *</p>
                <p>Later, on the 21st of May, he wrote<br/>two lines<br/>of verse.</p>
                <aside epub:type="footnote" id="n1"><p>A footnote that must not be read.</p></aside>
                <script>var x = 1;</script>
                </section>
                """)),
            ("OEBPS/ch1b.xhtml", xhtml("<p>The chapter continues in a second file, as publishers often split them.</p>")),
            ("OEBPS/ch2.xhtml", xhtml("<h1>The Second Chapter</h1><blockquote><p>A quoted epigraph.</p></blockquote><p>Plain &amp; simple text with <b>bold</b> words.</p><p><abbr>Mr.</abbr>&#160;Bennet was among the earliest\n      of those who waited. He had always intended to visit <abbr>Mr.</abbr>&#160;Bingley\u{FEFF}—truly.</p>")),
            ("OEBPS/nav.xhtml", xhtml("""
                <nav epub:type="toc"><ol>
                <li><a href="copyright.xhtml">Copyright</a></li>
                <li><a href="ch1.xhtml">Chapter One</a></li>
                <li><a href="ch2.xhtml#start">Chapter Two</a></li>
                </ol></nav>
                """)),
        ]
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>A Test Novel</dc:title><dc:creator>Ada Writer</dc:creator><dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cp" href="copyright.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1b" href="ch1b.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="cp"/><itemref idref="c1"/><itemref idref="c1b"/><itemref idref="c2"/></spine>
        </package>
        """
        let container = """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        var zip = ZipWriter()
        zip.add("mimetype", data: Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", data: Data(container.utf8))
        zip.add("OEBPS/content.opf", data: Data(opf.utf8))
        for (path, content) in files { zip.add(path, data: Data(content.utf8)) }
        return zip.finalize()
    }

    static func writeSampleEPUB(to dir: URL) -> URL {
        let url = dir.appendingPathComponent("sample.epub")
        try! sampleEPUB().write(to: url)
        return url
    }
}
