import Testing

@testable import ChauffeurCore

/// M4b spec §6: the agent sees a path's shape, never its identifiers, query or fragment.
@Suite struct PathShapeTests {
    @Test func queryAndFragmentAreDropped() {
        #expect(PathShape.shape("/search?q=secret&token=abc#top") == "/search")
        #expect(PathShape.shape("/search#top") == "/search")
    }

    @Test func numbersAndUUIDsBecomeIds() {
        #expect(PathShape.shape("/users/8812/orders") == "/users/{id}/orders")
        #expect(PathShape.shape("/items/3F2504E0-4F89-11D3-9A0C-0305E82C3301") == "/items/{id}")
    }

    @Test func emailsAndTokensAreCollapsed() {
        #expect(PathShape.shape("/reset/sam@example.com/7f3a9c1e5b2d4f60a8b1") == "/reset/{email}/{token}")
        #expect(PathShape.shape("/s/aGVsbG8gd29ybGQ9PT0x") == "/s/{token}")
    }

    @Test func percentEncodedEmailIsCollapsed() {
        #expect(PathShape.shape("/reset/sam%40example.com") == "/reset/{email}")
    }

    @Test func ordinarySegmentsStay() {
        #expect(PathShape.shape("/account-settings-overview") == "/account-settings-overview")
        #expect(PathShape.shape("/v2/users") == "/v2/users")
        #expect(PathShape.shape("/api/orders/") == "/api/orders/")
    }

    @Test func emptyIsRoot() {
        #expect(PathShape.shape("") == "/")
        #expect(PathShape.shape("?q=1") == "/")
        #expect(PathShape.shape("/") == "/")
    }
}
