import XCTest
@testable import HablaCore

/// Books in English, Spanish, German, Russian and Ukrainian: all readable; English and Spanish narratable.
final class LanguageTests: XCTestCase {
    static let samples: [(code: String, declared: String?, paragraphs: [String])] = [
        ("en", "en", ["It was a quiet morning in the village. Mr. Brown opened the shop at eight, earlier than usual.",
                      "Nobody knew who would come first. The girl at the window watched the road and thought about the distant city, where the trains never stopped."]),
        ("es", nil, ["Era una mañana tranquila en el pueblo. La Sra. García abrió la tienda a las ocho, antes de lo habitual.",
                     "Nadie sabía quién llegaría primero. La niña, que se llamaba Lucía, miraba por la ventana y pensaba en la ciudad lejana, donde los trenes nunca se detenían."]),
        ("de", "en", ["Es war ein ruhiger Morgen im Dorf. Herr Müller öffnete den Laden um acht Uhr, d. h. früher als sonst.",
                      "Die Donaudampfschifffahrtsgesellschaft hatte ihre Fahrpläne geändert, z. B. fuhren die Schiffe nun später. Niemand wusste, wer zuerst kommen würde, und das Mädchen am Fenster dachte an die ferne Stadt."]),
        ("ru", "ru-RU", ["Было тихое утро в деревне. Иван Петрович открыл лавку в восемь часов, т. е. раньше обычного.",
                         "Никто не знал, кто придёт первым. Девочка по имени Маша смотрела в окно и думала о далёком городе, где поезда никогда не останавливались."]),
        ("uk", "ru", ["Був тихий ранок у селі. Іван Петрович відчинив крамницю о восьмій годині, тобто раніше, ніж звичайно.",
                      "Ніхто не знав, хто прийде першим. Дівчинка на ім'я Марійка дивилася у вікно й думала про далеке місто, де потяги ніколи не зупинялися."]),
        ("fr", "fr", ["C'était un matin tranquille au village. Monsieur Lefèvre ouvrit la boutique à huit heures, plus tôt que d'habitude.",
                      "Personne ne savait qui viendrait en premier. La jeune fille à la fenêtre regardait la route et pensait à la ville lointaine, où les trains ne s'arrêtaient jamais."]),
        ("hi", "hi", ["गाँव में एक शांत सुबह थी। श्री शर्मा ने दुकान आठ बजे खोली, हमेशा से पहले।",
                      "किसी को नहीं पता था कि पहले कौन आएगा। खिड़की के पास बैठी लड़की सड़क देखती रही और दूर के शहर के बारे में सोचती रही, जहाँ रेलगाड़ियाँ कभी नहीं रुकती थीं।"]),
    ]

    static func epub(_ sample: (code: String, declared: String?, paragraphs: [String])) -> Data {
        // Two chapters with bare Roman-numeral headings, repeated text so detection has enough to go on.
        func chapter(_ n: String) -> Data {
            let ps = (sample.paragraphs + sample.paragraphs).map { "<p>\($0)</p>" }.joined()
            return Data(Fixtures.xhtml("<h1>\(n)</h1>\(ps)").utf8)
        }
        return Fixtures.customEPUB(title: "Sample \(sample.code)", chapters: [("1.xhtml", chapter("I")), ("2.xhtml", chapter("II"))],
                                   toc: [], language: sample.declared)
    }

    func testEachLanguageImportsReadableAndNarratesOnlyWithAVoice() throws {
        let root = Fixtures.tempDir()
        let expectedChapter = ["en": "Chapter", "es": "Capítulo", "de": "Kapitel", "ru": "Глава", "uk": "Розділ",
                               "fr": "Chapter", "hi": "Chapter"]   // French/Hindi keep the English word: no voice for them
        for sample in Self.samples {
            let url = Fixtures.write(Self.epub(sample), named: "\(sample.code).epub", in: root)
            let bundle = try BookImporter().importEPUB(at: url, into: root.appendingPathComponent("lib"))
            let m = try bundle.manifest()
            XCTAssertEqual(m.language, sample.code, "detected language (declared \(sample.declared ?? "nothing"))")
            let body = m.chapters.filter { !$0.isFrontMatter }
            XCTAssertEqual(body.count, 2, sample.code)
            if sample.code != "en" {
                // English keeps "I"/"II" (the app shows "Chapter I"); others are named in their language.
                XCTAssertEqual(body.first?.title, "\(expectedChapter[sample.code]!) I", sample.code)
            }
            let narratable = ["en", "es"].contains(sample.code)
            XCTAssertEqual(m.canNarrate, narratable, sample.code)
            XCTAssertTrue(body.allSatisfy { ($0.audioStatus == .pending) == narratable }, "\(sample.code): \(body.map(\.audioStatus))")

            // Abbreviations don't end sentences ("Sra. García", "d. h.", "z. B.", "т. е.").
            let text = try bundle.chapterText(body[0])
            let sentences = text.blocks.flatMap { b in b.sentences.map { b.substring($0.range) } }
            for s in sentences {
                XCTAssertFalse(["Sra.", "d.", "z.", "т."].contains { s.hasSuffix(" \($0)") }, "\(sample.code): split after an abbreviation: “\(s)”")
            }
            // Narration text: English rewrites only English ("Mr." → "Mister"), others untouched.
            let spoken = text.blocks.flatMap { b in b.sentences.compactMap(\.spoken) }.joined(separator: " ")
            if sample.code == "en" { XCTAssertTrue(spoken.contains("Mister Brown")) }
            else { XCTAssertFalse(spoken.contains("Mister") || spoken.contains("eight")) }
        }
    }

    func testLanguageCodesAndVoices() {
        XCTAssertEqual(BookLanguage.normalize("en-US"), "en")
        XCTAssertEqual(BookLanguage.normalize("ukr"), "uk")
        XCTAssertEqual(BookLanguage.normalize("ger"), "de")
        XCTAssertEqual(BookLanguage.defaultVoice(for: "es"), "em_alex")
        XCTAssertEqual(BookLanguage.closestVoice(to: "af_bella", for: "en"), "af_heart", "a Kokoro-only voice maps to the nearest one")
        XCTAssertEqual(BookLanguage.closestVoice(to: "bm_george", for: "en"), "bm_fable")
        XCTAssertEqual(BookLanguage.closestVoice(to: "ef_dora", for: "es"), "em_alex")
        XCTAssertFalse(BookLanguage.hasVoice("fr") || BookLanguage.hasVoice("hi"))
        XCTAssertFalse(BookLanguage.hasVoice("de") || BookLanguage.hasVoice("ru") || BookLanguage.hasVoice("uk"))
        // Languages without a voice fall back to the English voices (the old voice ids still map
        // somewhere); narration and voice pickers must check hasVoice, never rely on this fallback.
        XCTAssertEqual(BookLanguage.voices(for: "fr"), BookLanguage.voices(for: "en"))
        XCTAssertFalse(BookLanguage.voice("ff_siwis", speaks: "fr"), "retired voices are not offered")
        XCTAssertFalse(BookLanguage.voice("hf_alpha", speaks: "hi"))
        XCTAssertFalse(BookLanguage.voice("af_heart", speaks: "es"))
        XCTAssertTrue(BookLanguage.voice("em_alex", speaks: "es"))
        XCTAssertEqual(BookLanguage.name("de"), "German")
    }
}
