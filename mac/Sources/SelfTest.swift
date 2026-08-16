// SelfTest.swift
// Mirrors inkwell.py's --selftest so we can prove the Swift port is byte-compatible.
// Run: Inkwell.app/Contents/MacOS/Inkwell --selftest

import Foundation

enum SelfTest {

    static func run() -> Int32 {
        var ok = true

        func check(_ label: String, _ got: String, _ want: String) {
            if got != want {
                ok = false
                print("FAIL \(label)\n  got : \(got.debugDescription)\n  want: \(want.debugDescription)")
            } else {
                print("ok   \(label)")
            }
        }
        func checkRecs(_ label: String, _ got: [(name: String, scope: String)], _ want: [(String, String)]) {
            let g = got.map { "\($0.name)|\($0.scope)" }.joined(separator: " ;; ")
            let w = want.map { "\($0.0)|\($0.1)" }.joined(separator: " ;; ")
            check(label, g, w)
        }

        // splitSentences
        check("split basic", TextLogic.splitSentences("One.  Two?  ").joined(separator: "‖"), ["One.  ", "Two?  "].joined(separator: "‖"))
        check("split ellipsis", TextLogic.splitSentences("Wait...  Now.  ").joined(separator: "‖"), ["Wait...  ", "Now.  "].joined(separator: "‖"))

        // tag scope ladder
        checkRecs("scope mid-sentence", TextLogic.extractTagRecords(["The dog#dog# ran fast.  "]), [("dog", "The dog")])
        checkRecs("scope end-of-sentence", TextLogic.extractTagRecords(["The dog ran fast.  I saw it #dog#.  "]), [("dog", "The dog ran fast. I saw it")])
        checkRecs("scope tag-only sentence", TextLogic.extractTagRecords(["Hello there.  #cat#.  "]), [("cat", "Hello there.")])
        checkRecs("scope tag-only paragraph", TextLogic.extractTagRecords(["First para.  ", "#summary#.  "]), [("summary", "First para.")])

        // export
        check("export inline tag", TextLogic.renderExport(["The dog#dog# ran fast.  "]), "\tThe dog ran fast.\n")
        check("export drops tag-only sentence", TextLogic.renderExport(["Hello there.  #cat#.  "]), "\tHello there.\n")
        check("export drops tag-only paragraph", TextLogic.renderExport(["First para.  ", "#summary#.  "]), "\tFirst para.\n")
        check("export space before tag removed", TextLogic.renderExport(["I saw it #dog#.  "]), "\tI saw it.\n")

        print(ok ? "\nALL PASSED" : "\nSOME TESTS FAILED")
        return ok ? 0 : 1
    }
}
