import XCTest
@testable import Parfait

final class CalendarMatcherTests: XCTestCase {
    func testEventURLPreferredWhenProviderHost() {
        let url = URL(string: "https://us02web.zoom.us/j/123456789?pwd=abc")!
        XCTAssertEqual(
            CalendarMatcher.meetingLink(
                url: url,
                location: "https://meet.google.com/xyz-abcd-efg",
                notes: nil),
            url)
    }

    func testNonProviderEventURLFallsThroughToLocation() {
        let link = CalendarMatcher.meetingLink(
            url: URL(string: "https://example.com/agenda"),
            location: "Join: https://meet.google.com/abc-defg-hij",
            notes: nil)
        XCTAssertEqual(link, URL(string: "https://meet.google.com/abc-defg-hij"))
    }

    func testZoomLinkInLocationWithTrailingText() {
        let link = CalendarMatcher.meetingLink(
            url: nil,
            location: "https://company.zoom.us/j/987654321 (Passcode 1234)",
            notes: nil)
        XCTAssertEqual(link, URL(string: "https://company.zoom.us/j/987654321"))
    }

    func testGoogleLinkBuriedInHTMLNotes() {
        let notes = """
        <html><body>You have been invited to a meeting.<br>
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:-<br>
        <a href="https://meet.google.com/abc-defg-hij?hs=224">Join with Google Meet</a><br>
        Learn more at https://support.google.com/a/users/answer/9282720
        </body></html>
        """
        XCTAssertEqual(
            CalendarMatcher.meetingLink(url: nil, location: nil, notes: notes),
            URL(string: "https://meet.google.com/abc-defg-hij?hs=224"))
    }

    func testLocationScannedBeforeNotes() {
        let link = CalendarMatcher.meetingLink(
            url: nil,
            location: "https://zoom.us/j/111",
            notes: "https://meet.google.com/zzz-zzzz-zzz")
        XCTAssertEqual(link, URL(string: "https://zoom.us/j/111"))
    }

    func testProviderSubdomainsMatch() {
        for location in [
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc",
            "https://teams.live.com/meet/123",
            "https://acme.webex.com/meet/conrad",
            "https://subteam.whereby.com/standup",
            "https://meet.jit.si/OurRoom",
            "https://www.gotomeeting.com/join/123456789",
        ] {
            XCTAssertNotNil(
                CalendarMatcher.meetingLink(url: nil, location: location, notes: nil),
                location)
        }
    }

    func testNonProviderLinksIgnored() {
        XCTAssertNil(CalendarMatcher.meetingLink(
            url: nil,
            location: "Conference Room B",
            notes: "Agenda: https://docs.google.com/document/d/abc — see https://example.com"))
    }

    func testNothingAnywhereReturnsNil() {
        XCTAssertNil(CalendarMatcher.meetingLink(url: nil, location: nil, notes: nil))
        XCTAssertNil(CalendarMatcher.meetingLink(url: nil, location: "", notes: ""))
    }

    func testInsecureLinkIgnored() {
        // Only https links count when scanning text.
        XCTAssertNil(CalendarMatcher.meetingLink(
            url: nil, location: nil, notes: "http://zoom.us/j/123456"))
    }

    func testLookalikeHostsRejected() {
        // Suffix matching must anchor at a dot boundary, and the provider must
        // be the registrable host — not a path or a prefix.
        XCTAssertNil(CalendarMatcher.meetingLink(
            url: URL(string: "https://notzoom.us/j/1"), location: nil, notes: nil))
        XCTAssertNil(CalendarMatcher.meetingLink(
            url: nil, location: "https://zoom.us.evil.com/j/1", notes: nil))
        XCTAssertNil(CalendarMatcher.meetingLink(
            url: nil, location: nil, notes: "https://evil.com/meet.google.com"))
    }
}
