import Foundation
import Testing
@testable import MacScreenTransCore

// MARK: - Embedded-JSON extraction (models that wrap the object in prose)

@Test func responseExtractsEmbeddedJSONFromSurroundingProse() {
    let raw = """
    Here is the result you asked for:
    {"source_chunk":"an ironic twist","target_chunk":"讽刺的转折","word_pos":"n.","word_brief":"转折"}
    Hope this helps!
    """
    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response?.source == "an ironic twist")
    #expect(response?.target == "讽刺的转折")
}

@Test func responseSkipsStrayBraceBeforeRealObject() {
    let raw = "oops { not json — {\"source_chunk\":\"a phrase\",\"target_chunk\":\"短语\"}"
    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response?.source == "a phrase")
    #expect(response?.target == "短语")
}

@Test func responseHandlesBracesInsideStringLiterals() {
    let raw = "noise {\"source_chunk\":\"set {x} here\",\"target_chunk\":\"在此设置\"} trailing"
    let response = SenseGroupResponseRenderer.response(for: raw)
    #expect(response?.source == "set {x} here")
}

@Test func responseStillNilForStreamingPartialObject() {
    // A still-streaming object must NOT parse early.
    let raw = "{\"source_chunk\":\"an ironic tw"
    #expect(SenseGroupResponseRenderer.response(for: raw) == nil)
}

@Test func responseStillNilForPlainProse() {
    #expect(SenseGroupResponseRenderer.response(for: "这是一个普通的翻译结果。") == nil)
}

// MARK: - In-stream error payloads delivered with HTTP 200

@Test func errorMessageParsesSSEErrorChunk() {
    let line = #"data: {"error":{"message":"model 'missing' not found","code":404}}"#
    #expect(ChatCompletionStreamParser.errorMessage(fromSSELine: line) == "model 'missing' not found")
}

@Test func errorMessageParsesBareJSONErrorLine() {
    #expect(ChatCompletionStreamParser.errorMessage(fromSSELine: #"{"error":"runner crashed"}"#) == "runner crashed")
}

@Test func errorMessageIgnoresNormalChunksAndDone() {
    let delta = #"data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#
    #expect(ChatCompletionStreamParser.errorMessage(fromSSELine: delta) == nil)
    #expect(ChatCompletionStreamParser.errorMessage(fromSSELine: "data: [DONE]") == nil)
    #expect(ChatCompletionStreamParser.errorMessage(fromSSELine: "") == nil)
    // And the delta extractor must keep working on the same line.
    #expect(ChatCompletionStreamParser.contentDelta(fromSSELine: delta) == "hi")
}
