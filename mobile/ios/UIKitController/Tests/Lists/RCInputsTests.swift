import XCTest
@testable import RctlUIKit

@MainActor
final class RCSegmentedControlTests: XCTestCase {
    private var host: ListsTraitHost!

    override func setUp() async throws {
        host = ListsTraitHost(category: .large)
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    func testSegmentIndexFromXPosition() {
        // 3 pt inset + two 100 pt segments + 3 pt inset.
        let width: CGFloat = 206
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 4, width: width, count: 2), 0)
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 102.9, width: width, count: 2), 0)
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 103.1, width: width, count: 2), 1)
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 205, width: width, count: 2), 1)
    }

    func testSegmentIndexClampsDragsBeyondTheTrack() {
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: -40, width: 306, count: 3), 0)
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 900, width: 306, count: 3), 2)
        XCTAssertNil(RCSegmentedControl.segmentIndex(atX: 10, width: 306, count: 0))
    }

    func testSegmentIndexMirrorsInRightToLeft() {
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 10, width: 306, count: 3, rightToLeft: true), 2)
        XCTAssertEqual(RCSegmentedControl.segmentIndex(atX: 300, width: 306, count: 3, rightToLeft: true), 0)
    }

    func testSizeSelectsTrackHeight() {
        let control = host.host(RCSegmentedControl(items: [.init(title: "View"), .init(title: "Control")]))
        XCTAssertEqual(control.sizeThatFits(.zero).height, 40)
        control.size = .small
        XCTAssertEqual(control.sizeThatFits(.zero).height, 36)
        control.showsTitles = false
        XCTAssertGreaterThanOrEqual(control.sizeThatFits(.zero).width, RCLayout.minimumHitTarget * 2)

        let large = ListsTraitHost(category: .accessibilityExtraExtraExtraLarge)
        defer { large.tearDown() }
        let grown = large.host(RCSegmentedControl(items: [.init(title: "View"), .init(title: "Control")]))
        grown.size = .small
        let labelHeight = RCTypography.lineHeight(.footnoteStrong, compatibleWith: large.traits)
        XCTAssertGreaterThan(grown.sizeThatFits(.zero).height, labelHeight, "Tracks grow so large labels never clip")
    }

    func testProgrammaticSelectionDoesNotNotifyAndUpdatesVoiceOver() {
        let control = RCSegmentedControl(items: [.init(title: "View"), .init(title: "Control"), .init(title: "Keys")], style: .accentOn([1]))
        control.accessibilityHint = "View mode blocks all remote input"
        var changes: [Int] = []
        control.onChange = { changes.append($0) }
        control.setEnabled(false, forSegmentAt: 2)
        control.setSelectedIndex(1, animated: false)
        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertTrue(changes.isEmpty)

        let elements = control.accessibilityElements as? [UIAccessibilityElement] ?? []
        XCTAssertEqual(elements.map { $0.accessibilityLabel ?? "" }, ["View", "Control", "Keys"])
        XCTAssertTrue(elements[1].accessibilityTraits.contains(.selected))
        XCTAssertFalse(elements[0].accessibilityTraits.contains(.selected))
        XCTAssertTrue(elements[2].accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(elements[0].accessibilityHint, "View mode blocks all remote input")
    }

    func testVoiceOverActivationSelectsEnabledSegmentsOnly() {
        let control = RCSegmentedControl(items: [.init(title: "View"), .init(title: "Control")])
        var changes: [Int] = []
        control.onChange = { changes.append($0) }
        let elements = control.accessibilityElements as? [UIAccessibilityElement] ?? []
        control.setEnabled(false, forSegmentAt: 1)
        XCTAssertFalse(elements[1].accessibilityActivate())
        XCTAssertEqual(control.selectedIndex, 0)
        control.setEnabled(true, forSegmentAt: 1)
        XCTAssertTrue(elements[1].accessibilityActivate())
        XCTAssertEqual(control.selectedIndex, 1)
        XCTAssertEqual(changes, [1])
    }
}

@MainActor
final class RCTextFieldTests: XCTestCase {
    private let size = CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude)
    private var host: ListsTraitHost!

    override func setUp() async throws {
        host = ListsTraitHost(category: .large)
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    func testFieldWithoutMessageIsJustTheBox() {
        let field = host.host(RCTextField(label: "Name", placeholder: "Optional"))
        XCTAssertEqual(field.sizeThatFits(size).height, RCTextField.boxHeight(compatibleWith: field.traitCollection))
        XCTAssertGreaterThanOrEqual(field.sizeThatFits(size).height, RCLayout.minimumHitTarget)
    }

    func testHelperTextAddsItsHeightBelowTheBox() {
        let field = host.host(RCTextField(label: "Address"))
        let box = field.sizeThatFits(size).height
        field.helperText = "Port 8080 is used when none is given."
        let footnote = RCTypography.lineHeight(.footnote, compatibleWith: field.traitCollection)
        XCTAssertEqual(field.sizeThatFits(size).height, box + RCTextField.messageSpacing + footnote)
    }

    func testErrorMessageReplacesHelperText() {
        let field = host.host(RCTextField(label: "Address"))
        field.helperText = "Port 8080 is used when none is given."
        let withHelper = field.sizeThatFits(size).height
        field.errorMessage = "Enter a private address."
        XCTAssertEqual(field.sizeThatFits(size).height, withHelper, "One line of error replaces one line of helper")

        field.errorMessage = String(repeating: "Could not reach the local device. ", count: 4)
        XCTAssertGreaterThan(field.sizeThatFits(size).height, withHelper, "A long error wraps")
        XCTAssertEqual(field.textField.accessibilityHint?.hasPrefix("Error: "), true)

        field.displaysErrorMessage = false
        XCTAssertEqual(field.sizeThatFits(size).height, withHelper, "Hidden error message falls back to helper text")
        field.errorMessage = nil
        XCTAssertEqual(field.textField.accessibilityHint, "Port 8080 is used when none is given.")
    }

    func testMonospacedValueKeepsTheSameHeight() {
        let field = host.host(RCTextField(label: "Address"))
        let plain = field.sizeThatFits(size).height
        field.isMonospaced = true
        XCTAssertEqual(field.sizeThatFits(size).height, plain)
    }

    func testEditsNotifyAndProgrammaticTextDoesNot() {
        let field = RCTextField(label: "Name")
        var changes: [String] = []
        field.onChange = { changes.append($0) }
        field.text = "Studio"
        XCTAssertTrue(changes.isEmpty)
        field.textField.text = "Studio 2"
        field.textField.sendActions(for: .editingChanged)
        XCTAssertEqual(changes, ["Studio 2"])
    }

    func testInputAccessoryViewPassesThroughWithoutRecursing() {
        let field = RCTextField(label: "Name")
        let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        field.inputAccessoryView = accessory
        XCTAssertTrue(field.inputAccessoryView === accessory)
        XCTAssertTrue(field.textField.inputAccessoryView === accessory)
    }

    func testDisabledFieldCannotFocusAndExposesLabel() {
        let field = RCTextField(label: "Name")
        field.isEnabled = false
        XCTAssertFalse(field.textField.isEnabled)
        XCTAssertEqual(field.textField.accessibilityLabel, "Name")
        XCTAssertFalse(field.becomeFirstResponder())
    }
}
