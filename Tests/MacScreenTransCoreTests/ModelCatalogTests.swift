import Foundation
import Testing
@testable import MacScreenTransCore

@Test func modelCatalogEndpointAvoidsDuplicatingV1Path() {
    #expect(
        EndpointResolver.endpointURL(baseURL: "https://api.example.com/v1", path: ModelCatalogClient.modelsPath)?.absoluteString ==
            "https://api.example.com/v1/models"
    )
    #expect(
        EndpointResolver.endpointURL(baseURL: "http://127.0.0.1:11434", path: ModelCatalogClient.modelsPath)?.absoluteString ==
            "http://127.0.0.1:11434/v1/models"
    )
}

@Test func modelCatalogParsesOpenAISchemaSortedCaseInsensitively() throws {
    let payload = """
    {"object":"list","data":[
        {"id":"openai/gpt-4o-mini","object":"model"},
        {"id":"Anthropic/claude-sonnet","object":"model"},
        {"id":"deepseek/deepseek-chat","object":"model"}
    ]}
    """
    let ids = try ModelCatalogClient.modelIDs(fromResponseData: Data(payload.utf8))
    #expect(ids == ["Anthropic/claude-sonnet", "deepseek/deepseek-chat", "openai/gpt-4o-mini"])
}

@Test func modelCatalogParsesOllamaNativeTagsSchema() throws {
    let payload = """
    {"models":[
        {"name":"hf.co/tencent/Hy-MT2-7B-GGUF:Q8_0","modified_at":"2026-01-01T00:00:00Z"},
        {"model":"qwen2.5:7b"}
    ]}
    """
    let ids = try ModelCatalogClient.modelIDs(fromResponseData: Data(payload.utf8))
    #expect(ids == ["hf.co/tencent/Hy-MT2-7B-GGUF:Q8_0", "qwen2.5:7b"])
}

@Test func modelCatalogParsesBareArrayAndDeduplicates() throws {
    let payload = """
    ["b-model", {"id":"a-model"}, "b-model", {"id":"  "}, 42]
    """
    let ids = try ModelCatalogClient.modelIDs(fromResponseData: Data(payload.utf8))
    #expect(ids == ["a-model", "b-model"])
}

@Test func modelCatalogRejectsMalformedPayloads() {
    let garbage = Data("not json at all".utf8)
    #expect(throws: ModelCatalogError.malformedResponse) {
        try ModelCatalogClient.modelIDs(fromResponseData: garbage)
    }

    let wrongShape = Data(#"{"error":"nope"}"#.utf8)
    #expect(throws: ModelCatalogError.malformedResponse) {
        try ModelCatalogClient.modelIDs(fromResponseData: wrongShape)
    }
}
