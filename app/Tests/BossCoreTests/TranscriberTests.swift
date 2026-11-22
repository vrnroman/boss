import Testing
import Foundation
@testable import BossCore

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    let requests = Box<[URLRequest]>([])
    let response = Box<HTTPResult>(HTTPResult(status: 200, body: Data("{}".utf8)))
    let error = Box<Bool>(false)
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.mutate { $0.append(request) }
        if error.value { throw URLError(.cannotConnectToHost) }
        return response.value
    }
}

@Suite("Transcriber")
struct TranscriberTests {
    @Test func multipartBodyIsWellFormed() {
        var mp = MultipartBody(boundary: "XYZ")
        mp.addField("language", "auto")
        mp.addFile("file", filename: "a.wav", contentType: "audio/wav", Data("RIFF".utf8))
        let s = String(decoding: mp.finalized(), as: UTF8.self)
        #expect(s == "--XYZ\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nauto\r\n"
                   + "--XYZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n"
                   + "--XYZ--\r\n")
        #expect(mp.contentType == "multipart/form-data; boundary=XYZ")
    }

    @Test func requestHasAllWhisperFields() {
        let t = WhisperServerTranscriber()
        let req = t.makeRequest(wav: Data([0, 1]), prompt: "Sessions: payments.", language: nil, boundary: "B")
        #expect(req.url?.absoluteString == "http://127.0.0.1:8791/inference")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"file\"; filename=\"utterance.wav\""))
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nauto\r\n"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nSessions: payments.\r\n"))
    }

    @Test func lockedLanguageIsSent() {
        let req = WhisperServerTranscriber().makeRequest(wav: Data(), prompt: "", language: "ru", boundary: "B")
        let body = String(decoding: req.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nru\r\n"))
        #expect(!body.contains("name=\"prompt\""))   // empty prompt omitted
    }

    @Test func parsesVerboseJSONEnglish() throws {
        let j = #"{"task":"transcribe","language":"english","duration":2.1,"text":" Payments: run the tests.","segments":[]}"#
        let t = try WhisperServerTranscriber.parse(Data(j.utf8))
        #expect(t == Transcript(text: "Payments: run the tests.", lang: "en"))
    }

    @Test func parsesVerboseJSONRussian() throws {
        let j = #"{"language":"russian","text":" Гейтвей, запусти линтер."}"#
        #expect(try WhisperServerTranscriber.parse(Data(j.utf8)).lang == "ru")
    }

    @Test func fallsBackToSegmentsAndScriptGuess() throws {
        let j = #"{"segments":[{"text":" Привет"},{"text":" мир"}]}"#
        let t = try WhisperServerTranscriber.parse(Data(j.utf8))
        #expect(t.text == "Привет мир")
        #expect(t.lang == "ru")
    }

    @Test func badJSONThrows() {
        #expect(throws: TranscriberError.badResponse) { try WhisperServerTranscriber.parse(Data("nope".utf8)) }
    }

    @Test func httpErrorThrows() async {
        let tr = RecordingTransport()
        tr.response.value = HTTPResult(status: 500, body: Data("boom".utf8))
        await #expect(throws: TranscriberError.self) {
            _ = try await WhisperServerTranscriber(transport: tr).transcribe(wav: Data(), prompt: "", language: nil)
        }
    }

    @Test func languageNormalization() {
        #expect(LanguageCode.normalize("english") == "en")
        #expect(LanguageCode.normalize("Russian") == "ru")
        #expect(LanguageCode.normalize("ru") == "ru")
        #expect(LanguageCode.normalize("") == nil)
        #expect(LanguageCode.normalize(nil) == nil)
        #expect(LanguageCode.guess("hello") == "en")
        #expect(LanguageCode.guess("123") == nil)
    }

    @Test func vocabularyPrompt() {
        #expect(VocabularyPrompt.build(sessionNames: ["payments", "boss", "Payments", "titan-otc"], words: ["Apigee", " ", "Titan"])
                == "Sessions (payments, titan-otc, etc). Words (Apigee, Titan, etc).")
        #expect(VocabularyPrompt.build(sessionNames: [], words: []) == "")
        #expect(VocabularyPrompt.build(sessionNames: ["a"], words: []) == "Sessions (a, etc).")
    }

    @Test func vocabularyPromptNeverEndsWithABareName() {
        // the format that made whisper drop the first spoken session name must not come back
        let p = VocabularyPrompt.build(sessionNames: ["payments", "gateway"], words: [])
        #expect(p.hasSuffix(", etc)."))
        #expect(!p.contains("Sessions:"))
    }

    @Test func vocabularyPromptTrimsWholeEntries() {
        let names = (0..<100).map { "session-\($0)" }
        let p = VocabularyPrompt.build(sessionNames: names, words: ["Apigee"], maxChars: 120)
        #expect(p.count <= 120)
        #expect(p.hasSuffix(", etc)."))
        #expect(!p.contains("Words"))   // words go first, then names
    }
}

@Suite("HallucinationFilter")
struct HallucinationTests {
    @Test(arguments: ["Thank you.", "Thanks for watching!", "Продолжение следует...", "Субтитры сделал DimaTorzok",
                      "", "   ", "...", "!?", "[BLANK_AUDIO]", "(music)", "Thank you. Thank you. Thank you.",
                      "Спасибо за просмотр!", " you", "Редактор субтитров А.Синецкая Корректор А.Егорова"])
    func drops(_ s: String) { #expect(HallucinationFilter.clean(s) == nil) }

    @Test(arguments: ["Thank you, run the tests.", "Payments: rename the fee calculator.", "Гейтвей, запусти линтер.",
                      "gateway", "Okay", "yes", "Спасибо, отправь это в payments"])
    func keeps(_ s: String) { #expect(HallucinationFilter.clean(s) != nil) }

    @Test func cleansBlankTagsAndWhitespace() {
        #expect(HallucinationFilter.clean("[BLANK_AUDIO] run   the tests ") == "run the tests")
    }
}
