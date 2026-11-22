import XCTest
@testable import ParadeeKit

final class ModelTests: XCTestCase {
    func testWaveformMatchesPython() throws {
        let model = try ParadeeModel(model: ParadeeResources.url("paradee_int8.onnx"), config: ParadeeResources.url("paradee_config.json"))
        let audio = try model.generate(phonemes: "həlˈO ðˈɛɹ, ðɪs ɪz ɐ tˈɛst ʌv ðə nˈɛɹˌATəɹ.", speed: 1, voice: "af_heart")
        let ref = try Data(contentsOf: Bundle.module.url(forResource: "Fixtures/ref_hello", withExtension: "f32")!)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(audio.count, ref.count)
        // The decoder adds random noise (Python differs from itself by as much), so compare the
        // waveforms' correlation: two Python runs correlate at about 0.94.
        let r = correlation(audio, ref)
        print("correlation with Python: \(r)")
        XCTAssertGreaterThan(r, 0.85)
    }

    func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let n = Double(min(a.count, b.count))
        let ma = a.reduce(0.0) { $0 + Double($1) } / n, mb = b.reduce(0.0) { $0 + Double($1) } / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for (x, y) in zip(a, b) { let dx = Double(x) - ma, dy = Double(y) - mb; sab += dx * dy; saa += dx * dx; sbb += dy * dy }
        return sab / (saa * sbb).squareRoot()
    }
}
