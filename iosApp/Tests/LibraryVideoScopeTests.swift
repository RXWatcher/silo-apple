import XCTest
@testable import Silo

final class LibraryVideoScopeTests: XCTestCase {
    func testSectionPagingDoesNotSendFilterOverlays() throws {
        var query = APIv2CatalogQuery()
        query.source = "section"
        query.scope = "library"
        query.libraryId = "7"
        query.sectionId = "recent"
        query.limit = 100
        let parameters = try query.getParameters()
        XCTAssertEqual(parameters["section_id"], "recent")
        XCTAssertEqual(parameters["library_id"], "7")
        XCTAssertNil(parameters["match"])
        XCTAssertNil(parameters["type"])
        XCTAssertNil(parameters["sort"])
    }

    func testPagedEpisodePreservesPlaybackContext() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(BrowseItem.self, from: Data("""
        {"content_id":"episode","type":"episode","title":"Episode","series_id":"show","series_title":"Show",
         "season_number":2,"episode_number":3,"position_seconds":73,"duration_seconds":1200,"item_source":"continue_watching"}
        """.utf8))
        let sectionItem = SectionItem(browseItem: item)
        XCTAssertEqual(sectionItem.seriesId, "show")
        XCTAssertEqual(sectionItem.seasonNumber, 2)
        XCTAssertEqual(sectionItem.episodeNumber, 3)
        XCTAssertEqual(sectionItem.positionSeconds, 73)
        XCTAssertEqual(sectionItem.durationSeconds, 1200)
        XCTAssertEqual(sectionItem.itemSource, "continue_watching")
    }

    func testSeriesTabCannotBeBroadenedBySavedTypeOrMatchAny() throws {
        var filters = CatalogFilterState()
        filters.mediaScope = "movie"
        filters.matchAll = false
        filters.genres = ["Drama"]
        let query = try CatalogQueryBuilder.build(filters, libraryId: 7, mediaType: .mixed,
                                                  limit: 60, includeType: false,
                                                  enforcedScope: .series).getParameters()
        XCTAssertEqual(query["type"], "series")
        XCTAssertEqual(query["library_id"], "7")
        XCTAssertEqual(query["match"], "any")
        let groups = try XCTUnwrap(query["groups"])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(groups.utf8)) as? [[String: Any]])
        let rules = decoded.flatMap { $0["rules"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(rules.compactMap { $0["field"] as? String }, ["genre"])
    }

    func testSeriesShelfRefillsBeyondFirstMoviePage() async throws {
        let film = try item("film", "movie")
        let show = try item("show", "series")
        let original = row(items: [film], total: 2, limit: 1)
        var cursors: [Int?] = []
        let result = try await LibraryVideoScope.series.refill(original) { (cursor: Int?) in
            cursors.append(cursor)
            return cursor == nil ? LibraryScopedPage(items: [film], next: 1)
                : LibraryScopedPage(items: [show], next: nil)
        }
        XCTAssertEqual(cursors, [nil, 1])
        XCTAssertEqual(result.section.items.map(\.id), ["show"])
        XCTAssertFalse(result.incomplete)
        XCTAssertNil(result.section.totalCount, "The unfiltered total must not be shown as a typed count")
    }

    func testCompleteInlineShelfKeepsEpisodeProgressWithoutRefetch() async throws {
        let episode = try item("episode", "episode", progress: 73)
        let film = try item("film", "movie")
        let result = try await LibraryVideoScope.series.refill(row(items: [film, episode], total: 2)) { (_: Int?) -> LibraryScopedPage<Int> in
            XCTFail("A complete inline shelf should not be fetched again")
            return LibraryScopedPage(items: [], next: nil)
        }
        XCTAssertEqual(result.section.items.map(\.id), ["episode"])
        XCTAssertEqual(result.section.items.first?.positionSeconds, 73)
        XCTAssertFalse(result.incomplete)
    }

    func testBoundedRefillDoesNotClaimAnEmptyLibraryWhenMatchingItemsMayBeLater() async throws {
        let film = try item("film", "movie")
        var reads = 0
        let result = try await LibraryVideoScope.series.refill(row(items: [film], total: 10_000)) { (cursor: Int?) in
            reads += 1
            return LibraryScopedPage(items: [film], next: reads)
        }
        XCTAssertEqual(reads, 8)
        XCTAssertTrue(result.incomplete)
        XCTAssertTrue(result.section.items.isEmpty)
    }

    func testMoviesRejectSeriesAndEpisodes() {
        XCTAssertTrue(LibraryVideoScope.movie.contains(" Movie "))
        XCTAssertFalse(LibraryVideoScope.movie.contains("series"))
        XCTAssertFalse(LibraryVideoScope.movie.contains("episode"))
        XCTAssertFalse(LibraryVideoScope.series.contains("audiobook"))
    }

    private func item(_ id: String, _ type: String, progress: Int = 0) throws -> SectionItem {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SectionItem.self, from: Data("""
        {"content_id":"\(id)","type":"\(type)","title":"\(id)","position_seconds":\(progress)}
        """.utf8))
    }

    private func row(items: [SectionItem], total: Int, limit: Int = 20) -> ResolvedSection {
        ResolvedSection(id: "recent", sectionType: "recently_added", title: "Recent", featured: false,
                        itemLimit: limit, totalCount: total, isCustom: false, customized: false, items: items)
    }
}
