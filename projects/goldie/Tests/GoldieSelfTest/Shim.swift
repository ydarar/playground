// Debug-only: release builds can't @testable import. Run with `swift run goldie-selftest`.
#if DEBUG
import Foundation

// A tiny stand-in for XCTest so the tests run with only the Command Line Tools
// (which don't ship XCTest). Same assertion names, so tests read like normal XCTest.

class XCTestCase {
    init() {}
}

enum SelfTest {
    static var failures: [String] = []

    static func fail(_ message: String, _ file: StaticString, _ line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }
}

struct UnwrapFailed: Error {}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if x != y { SelfTest.fail("XCTAssertEqual failed: (\(x)) is not equal to (\(y)) \(message())", file, line) }
    } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T,
                                      _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if abs(x - y) > accuracy { SelfTest.fail("XCTAssertEqual failed: (\(x)) is not within \(accuracy) of (\(y)) \(message())", file, line) }
    } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do { if try !a() { SelfTest.fail("XCTAssertTrue failed \(message())", file, line) } } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() { SelfTest.fail("XCTAssertFalse failed \(message())", file, line) } } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    do { if let v = try a() { SelfTest.fail("XCTAssertNil failed: \(v) \(message())", file, line) } } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertNotNil(_ a: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == nil { SelfTest.fail("XCTAssertNotNil failed \(message())", file, line) } } catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if !(x > y) { SelfTest.fail("XCTAssertGreaterThan failed: \(x) <= \(y)", file, line) } }
    catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if !(x >= y) { SelfTest.fail("XCTAssertGreaterThanOrEqual failed: \(x) < \(y)", file, line) } }
    catch { SelfTest.fail("threw \(error)", file, line) }
}

func XCTUnwrap<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try a() else {
        SelfTest.fail("XCTUnwrap failed: nil", file, line)
        throw UnwrapFailed()
    }
    return v
}
#endif
