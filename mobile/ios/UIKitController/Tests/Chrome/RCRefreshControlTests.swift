import XCTest
@testable import RctlUIKit

@MainActor
final class RCRefreshControlTests: XCTestCase {
    private func makeScrollView(_ behavior: UIScrollView.ContentInsetAdjustmentBehavior, top: CGFloat) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 700))
        scrollView.contentInsetAdjustmentBehavior = behavior
        scrollView.contentInset.top = top
        scrollView.contentSize = CGSize(width: 375, height: 1400)
        scrollView.contentOffset.y = -scrollView.adjustedContentInset.top
        return scrollView
    }

    func testInstallsBehindContentWithoutTakingTouches() {
        let scrollView = makeScrollView(.never, top: 52)
        let content = UIView()
        scrollView.addSubview(content)
        let control = RCRefreshControl(scrollView: scrollView) {}
        XCTAssertTrue(control.superview === scrollView)
        XCTAssertLessThan(scrollView.subviews.firstIndex(of: control) ?? .max, scrollView.subviews.firstIndex(of: content) ?? 0)
        XCTAssertFalse(control.isUserInteractionEnabled)
    }

    func testProgrammaticRefreshHoldsAndReleasesInsetAdditively() async {
        for behavior in [UIScrollView.ContentInsetAdjustmentBehavior.never, .automatic] {
            let scrollView = makeScrollView(behavior, top: 52)
            let finished = expectation(description: "refresh ran")
            var runs = 0
            let control = RCRefreshControl(scrollView: scrollView) {
                runs += 1
                finished.fulfill()
            }
            control.beginRefreshing()
            XCTAssertTrue(control.isRefreshing)
            XCTAssertEqual(scrollView.contentInset.top, 52 + control.refreshingHeight, accuracy: 0.01)
            await fulfillment(of: [finished], timeout: 2)
            // The completion runs after `onRefresh` returns on the main actor.
            await Task.yield()
            XCTAssertFalse(control.isRefreshing)
            XCTAssertEqual(scrollView.contentInset.top, 52, accuracy: 0.01, "\(behavior) keeps the screen's own inset")
            XCTAssertEqual(runs, 1)
        }
    }

    func testScreenInsetChangesDuringRefreshSurvive() async {
        let scrollView = makeScrollView(.never, top: 52)
        let control = RCRefreshControl(scrollView: scrollView) {
            try? await Task.sleep(seconds: 10)
        }
        control.beginRefreshing()
        scrollView.contentInset.top += 20
        control.endRefreshing()
        XCTAssertEqual(scrollView.contentInset.top, 72, accuracy: 0.01)
    }

    func testOwnerReassigningBaseInsetKeepsHeldGap() {
        let scrollView = makeScrollView(.never, top: 52)
        let control = RCRefreshControl(scrollView: scrollView) {
            try? await Task.sleep(seconds: 10)
        }
        control.beginRefreshing()
        // Typical screen layout pass: absolute assignment of its own base inset.
        scrollView.contentInset.top = 52
        control.scrollViewDidScroll()
        XCTAssertEqual(scrollView.contentInset.top, 52 + control.refreshingHeight, accuracy: 0.01)
        scrollView.contentInset.top = 52
        control.endRefreshing()
        XCTAssertEqual(scrollView.contentInset.top, 52, accuracy: 0.01)
    }

    func testScrollingContentWritesNothingWhileTheIndicatorIsHidden() {
        let scrollView = makeScrollView(.never, top: 52)
        let control = RCRefreshControl(scrollView: scrollView) {}
        let rest = -scrollView.adjustedContentInset.top
        control.scrollViewDidScroll()
        let parked = control.indicatorWriteCount
        for offset in stride(from: rest, through: rest + 600, by: 7) {
            scrollView.contentOffset.y = offset
            control.scrollViewDidScroll()
        }
        XCTAssertEqual(control.indicatorWriteCount, parked, "scrolling content must not touch the hidden indicator")
        XCTAssertEqual(control.alpha, 0)

        // A pull shows it again and every pull step updates it.
        scrollView.contentOffset.y = rest - 40
        control.scrollViewDidScroll()
        XCTAssertGreaterThan(control.alpha, 0)
        scrollView.contentOffset.y = rest - 50
        control.scrollViewDidScroll()
        XCTAssertEqual(control.indicatorWriteCount, parked + 2)

        // Returning to rest hides it once, then parks again.
        scrollView.contentOffset.y = rest
        control.scrollViewDidScroll()
        XCTAssertEqual(control.alpha, 0)
        let hidden = control.indicatorWriteCount
        scrollView.contentOffset.y = rest + 100
        control.scrollViewDidScroll()
        XCTAssertEqual(control.indicatorWriteCount, hidden)
    }

    func testRefreshingIndicatorFollowsScrollingWhileHeld() {
        let scrollView = makeScrollView(.never, top: 52)
        let control = RCRefreshControl(scrollView: scrollView) {
            try? await Task.sleep(seconds: 10)
        }
        control.beginRefreshing()
        let before = control.indicatorWriteCount
        scrollView.contentOffset.y += 30
        control.scrollViewDidScroll()
        XCTAssertEqual(control.indicatorWriteCount, before + 1, "the held spinner keeps tracking the content")
        control.endRefreshing()
    }

    func testLateCompletionOfAnEndedRefreshDoesNotEndTheNextOne() async {
        let scrollView = makeScrollView(.never, top: 0)
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let control = RCRefreshControl(scrollView: scrollView) {
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { gate = $0 }
            } else {
                try? await Task.sleep(seconds: 10)
            }
        }
        control.beginRefreshing()
        await Task.yield()
        control.endRefreshing()
        control.beginRefreshing()
        gate?.resume()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(control.isRefreshing, "The first refresh's completion must not end the second")
        control.endRefreshing()
    }
}
