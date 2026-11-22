import Foundation

/// The model files bundled with the app (fetched by Scripts/fetch-paradee.sh).
enum ParadeeResources {
    static func url(_ name: String) throws -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw ParadeeError.missingResource(name)
        }
        return u
    }
}
