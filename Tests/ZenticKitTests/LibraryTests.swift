import Foundation
import Testing

@testable import ZenticKit

private func entry(_ url: String, _ title: String = "", at date: Date) -> HistoryEntry {
    HistoryEntry(url: URL(string: url)!, title: title, lastVisit: date, visits: 1)
}

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ text: String) -> Date {
    // Local New York wall-clock time, so the tests read like the dates they mean.
    let formatter = DateFormatter()
    formatter.calendar = newYork
    formatter.timeZone = newYork.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

@Suite struct HistoryRangeTests {
    @Test func yesterdayBeginsAtItsMidnightOnTheDayTheClocksChange() throws {
        // US clocks went back at 02:00 on 1 November 2026: that day was 25 hours
        // long. Counting back 48 hours from 10:00 on the 2nd lands at 11:00 on
        // 31 October — and would clear a visit from the evening of the 31st.
        let now = date("2026-11-02 10:00")
        let start = try #require(HistoryRange.todayAndYesterday.start(now: now, calendar: newYork))
        #expect(start == date("2026-11-01 00:00"))

        let entries = [
            entry("https://a.example/", at: date("2026-10-31 23:30")),
            entry("https://b.example/", at: date("2026-11-01 00:30")),
            entry("https://c.example/", at: date("2026-11-02 09:00")),
        ]
        let kept = HistoryRange.todayAndYesterday.kept(entries, now: now, calendar: newYork)
        #expect(kept.map(\.url.host) == ["a.example"])
    }

    @Test func eachRangeClearsExactlyItsSpan() {
        let now = date("2026-10-04 15:00")
        let entries = [
            entry("https://minutes.example/", at: date("2026-10-04 14:30")),
            entry("https://morning.example/", at: date("2026-10-04 08:00")),
            entry("https://yesterday.example/", at: date("2026-10-03 12:00")),
            entry("https://lastweek.example/", at: date("2026-09-27 12:00")),
        ]
        func kept(_ range: HistoryRange) -> [String?] {
            range.kept(entries, now: now, calendar: newYork).map(\.url.host)
        }
        #expect(kept(.lastHour) == ["morning.example", "yesterday.example", "lastweek.example"])
        #expect(kept(.today) == ["yesterday.example", "lastweek.example"])
        #expect(kept(.todayAndYesterday) == ["lastweek.example"])
        #expect(kept(.all).isEmpty)
    }

    @Test func aVisitExactlyAtTheBoundaryIsCleared() {
        let now = date("2026-10-04 15:00")
        let entries = [entry("https://edge.example/", at: date("2026-10-04 00:00"))]
        #expect(HistoryRange.today.kept(entries, now: now, calendar: newYork).isEmpty)
    }
}

@Suite struct HistoryGroupingTests {
    @Test func groupsByLocalDayNewestFirst() {
        // 23:30 and 00:30 local are an hour apart but on different days —
        // and in UTC both fall on the same day, which grouping must not use.
        let entries = [
            entry("https://late.example/", at: date("2026-10-03 23:30")),
            entry("https://early.example/", at: date("2026-10-04 00:30")),
            entry("https://noon.example/", at: date("2026-10-04 12:00")),
        ]
        let days = HistoryDay.group(entries, calendar: newYork)
        #expect(days.map(\.day) == [date("2026-10-04 00:00"), date("2026-10-03 00:00")])
        #expect(days[0].entries.map(\.url.host) == ["noon.example", "early.example"])
        #expect(days[1].entries.map(\.url.host) == ["late.example"])
    }

    @Test func searchMatchesEveryWordInTitleOrAddress() {
        let entries = [
            entry("https://github.com/luka/zentic", "luka/zentic: a browser", at: date("2026-10-04 12:00")),
            entry("https://github.com/apple/swift", "apple/swift", at: date("2026-10-04 11:00")),
            entry("https://zentic.example/", "Zentic", at: date("2026-10-04 10:00")),
        ]
        let days = HistoryDay.group(entries, matching: "  GitHub   zentic ", calendar: newYork)
        #expect(days.flatMap(\.entries).map(\.url.absoluteString) == ["https://github.com/luka/zentic"])
        #expect(HistoryDay.group(entries, matching: "nothing", calendar: newYork).isEmpty)
    }

    @Test func savedHistoryStillDecodesAndKeepsItsSearchIndex() throws {
        // The file written before the History window existed.
        let json = #"[{"url":"https://Example.com/Path","title":"Hello World","lastVisit":"2026-10-04T10:00:00Z","visits":3}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(decoded.first?.visits == 3)
        #expect(decoded.first?.matches(words: ["hello", "path"]) == true)
    }
}

@Suite struct BookmarkImportTests {
    /// Abridged from a real Chrome export.
    static let chrome = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000001" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://news.ycombinator.com/" ADD_DATE="1700000000" ICON="data:image/png;base64,AAA=">Hacker News</A>
                <DT><H3 ADD_DATE="1700000000">Recipes</H3>
                <DL><p>
                    <DT><A HREF="https://cooking.example/soup?a=1&amp;b=2">Soup &amp; Bread</A>
                    <DT><H3>Desserts</H3>
                    <DL><p>
                        <DT><A HREF="https://cooking.example/cake">Cake</A>
                    </DL><p>
                </DL><p>
                <DT><A HREF="javascript:alert('bookmarklet')">Bookmarklet</A>
            </DL><p>
            <DT><H3>Other bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://swift.org/">Swift &#8212; the language</A>
            </DL><p>
            <DT><H3>Only bookmarklets</H3>
            <DL><p>
                <DT><A HREF="javascript:void(0)">Nothing</A>
            </DL><p>
        </DL><p>
        """

    @Test func toolbarFolderIsSeeThroughAndDeeperFoldersFlatten() {
        let items = BookmarkImport.parse(Self.chrome)
        #expect(items.map(\.title) == ["Hacker News", "Recipes", "Other bookmarks"])
        #expect(items[0].url == URL(string: "https://news.ycombinator.com/"))
        // Desserts was inside Recipes: its bookmark joins Recipes.
        #expect(items[1].isFolder)
        #expect(items[1].children.map(\.title) == ["Soup & Bread", "Cake"])
        #expect(items[1].children.allSatisfy { !$0.isFolder })
    }

    @Test func entitiesAreDecodedInTitlesAndAddresses() {
        let items = BookmarkImport.parse(Self.chrome)
        #expect(items[1].children[0].url?.absoluteString == "https://cooking.example/soup?a=1&b=2")
        #expect(items[2].children[0].title == "Swift — the language")
    }

    @Test func bookmarkletsAndEmptyFoldersAreLeftOut() {
        let items = BookmarkImport.parse(Self.chrome)
        #expect(!items.contains { $0.title == "Only bookmarklets" })
        #expect(!items.flatMap(\.flattened).contains { $0.url?.scheme == "javascript" })
    }

    @Test func safariExportWithSingleQuotesLowercaseTagsAndNoTitles() {
        let html = """
            <dl><p>
            <dt><h3 folded>Favourites</h3>
            <dl><p>
            <dt><a href='https://apple.com/'>Apple</a>
            <dt><a href="https://untitled.example/page"></a>
            </dl><p>
            <dt><a href="https://loose.example/">Loose</a>
            <dt><A HREF="place:sort=8">Firefox smart folder</A>
            </dl><p>
            """
        let items = BookmarkImport.parse(html)
        #expect(items.map(\.title) == ["Favourites", "Loose"])
        #expect(items[0].children.map(\.title) == ["Apple", "untitled.example"])
    }

    @Test func malformedInputNeverCrashesOrLoops() {
        for html in ["", "<", "<DL>", "</DL></DL>", "<A HREF=\"https://x.example/\">no close", "<H3>Folder", "&#xFFFFFFFF;<DL"] {
            _ = BookmarkImport.parse(html)
        }
        #expect(BookmarkImport.decodeEntities("a &unknown; b & c &#x1F600;") == "a &unknown; b & c 😀")
    }
}

@Suite struct BookmarkListTests {
    @Test func importingTheSameFileTwiceAddsNothingTheSecondTime() {
        var list = BookmarkList()
        let first = list.merge(BookmarkImport.parse(BookmarkImportTests.chrome))
        #expect(first == 4)
        let second = list.merge(BookmarkImport.parse(BookmarkImportTests.chrome))
        #expect(second == 0)
        #expect(list.items.filter(\.isFolder).map(\.title) == ["Recipes", "Other bookmarks"])
    }

    @Test func importIntoAnExistingFolderOfTheSameName() {
        var list = BookmarkList()
        let recipes = list.addFolder("Recipes")
        list.add(URL(string: "https://mine.example/")!, title: "Mine", in: recipes)
        list.merge(BookmarkImport.parse(BookmarkImportTests.chrome))
        #expect(list.item(recipes)?.children.map(\.title) == ["Mine", "Soup & Bread", "Cake"])
    }

    @Test func foldersNeverNest() throws {
        var list = BookmarkList()
        let a = list.addFolder("A")
        let b = list.addFolder("B")
        list.move(b, into: a)
        #expect(list.item(a)?.children.isEmpty == true)
        #expect(list.items.count == 2)

        // A hand-edited or future file with a folder in a folder.
        let json = """
            {"items":[{"id":"\(UUID())","title":"Outer","children":[
              {"id":"\(UUID())","title":"Inner","children":[
                {"id":"\(UUID())","title":"Deep","url":"https://deep.example/","children":[]}]}]}]}
            """
        let decoded = try JSONDecoder().decode(BookmarkList.self, from: Data(json.utf8))
        #expect(decoded.items[0].children.map(\.title) == ["Deep"])
    }

    @Test func movingBetweenLevelsAndReordering() {
        var list = BookmarkList()
        let folder = list.addFolder("Reading")
        let one = list.add(URL(string: "https://one.example/")!, title: "One")
        let two = list.add(URL(string: "https://two.example/")!, title: "Two")
        list.move(one, into: folder)
        #expect(list.items.map(\.title) == ["Reading", "Two"])
        #expect(list.item(folder)?.children.map(\.id) == [one])

        // Drag "Two" above "Reading", as List.onMove reports it.
        list.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(list.items.map(\.id) == [two, folder])

        list.move(one, into: nil)
        #expect(list.items.map(\.title) == ["Two", "Reading", "One"])
    }

    @Test func removingAFolderRemovesItsBookmarks() {
        var list = BookmarkList()
        let folder = list.addFolder("F")
        list.add(URL(string: "https://in.example/")!, title: "In", in: folder)
        list.remove([folder])
        #expect(list.all.isEmpty)
        #expect(!list.contains(URL(string: "https://in.example/")!))
    }

    @Test func renameIgnoresABlankTitle() {
        var list = BookmarkList()
        let id = list.add(URL(string: "https://x.example/")!, title: "X")
        list.rename(id, to: "   ")
        #expect(list.item(id)?.title == "X")
        list.rename(id, to: " Better ")
        #expect(list.item(id)?.title == "Better")
    }
}
