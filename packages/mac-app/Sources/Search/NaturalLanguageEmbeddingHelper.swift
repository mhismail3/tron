import Foundation
import NaturalLanguage

private struct Request: Decodable {
    let id: String
    let text: String
    let language: String?
}

private struct Response: Encodable {
    let id: String
    let vector: [Double]?
    let dimension: Int
    let language: String
    let modelRevision: String
    let reason: String?
}

@main
struct NaturalLanguageEmbeddingHelper {
    private static let maximumFrameBytes = 16 * 1024
    private static let maximumTextBytes = 8 * 1024

    static func main() {
        while let line = readLine(strippingNewline: true) {
            let data = Data(line.utf8)
            guard data.count <= maximumFrameBytes,
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  !request.id.isEmpty,
                  Data(request.text.utf8).count <= maximumTextBytes else {
                emit(Response(id: "", vector: nil, dimension: 0, language: "", modelRevision: "", reason: "invalid_frame"))
                continue
            }
            let language = request.language.flatMap(NLLanguage.init(rawValue:)) ?? .english
            guard let embedding = NLEmbedding.sentenceEmbedding(for: language),
                  let vector = embedding.vector(for: request.text) else {
                emit(Response(id: request.id, vector: nil, dimension: embeddingDimension(language), language: language.rawValue, modelRevision: modelRevision(language), reason: "unsupported_language_or_text"))
                continue
            }
            emit(Response(id: request.id, vector: vector, dimension: vector.count, language: language.rawValue, modelRevision: modelRevision(embedding), reason: nil))
        }
    }

    private static func modelRevision(_ embedding: NLEmbedding) -> String {
        "sentence:\(embedding.language?.rawValue ?? "unknown"):\(embedding.revision)"
    }

    private static func modelRevision(_ language: NLLanguage) -> String {
        "sentence:\(language.rawValue):\(NLEmbedding.currentSentenceEmbeddingRevision(for: language))"
    }

    private static func embeddingDimension(_ language: NLLanguage) -> Int {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return 0 }
        return embedding.dimension
    }

    private static func emit(_ response: Response) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
