///|
test "MoonBit highlighter preserves exact text and uses lexer token classes" {
  let source = "\tpub fn greet(名字 : String) -> Int { // 注释 🌙"
  for path in ["main.mbt", "pkg.generated.mbti", "scripts/check.mbtx"] {
    let highlight = @highlight.for_path(path).unwrap()
    let spans = highlight(source)
    assert_eq(spans.map(span => span.text).join(""), source)
    assert_true(
      spans
      .iter()
      .any(span => span.text == "pub" && span.style.fg is Rgb(86, 156, 214)),
    )
    assert_true(
      spans
      .iter()
      .any(span => span.text == "greet" && span.style.fg is Rgb(220, 220, 170)),
    )
    assert_true(
      spans
      .iter()
      .any(span => span.text == "String" && span.style.fg is Rgb(78, 201, 176)),
    )
    assert_true(
      spans
      .iter()
      .any(span => {
        span.text == "// 注释 🌙" && span.style.fg is Rgb(106, 153, 85)
      }),
    )
  }
  assert_true(@highlight.for_path("README.mbt.md") is None)
  assert_true(@highlight.for_path("main.txt") is None)
}

///|
test "strings numbers incomplete edits and diff backgrounds remain intact" {
  let base = @tui.Style(bg=Rgb(20, 45, 32), reverse=true)
  let highlight = @highlight.for_path("main.mbt", base~).unwrap()
  for
    source in [
      "let x = 42", "let s = \"你好 🌙\\n\"", "let s = \"unfinished", "#|literal text",
      "$|hello \\{x}", "", "  ",
    ] {
    let spans = highlight(source)
    assert_eq(spans.map(span => span.text).join(""), source)
    for span in spans {
      assert_eq(span.style.bg, base.bg)
      assert_true(span.style.reverse)
    }
  }
  assert_true(highlight("42")[0].style.fg is Rgb(181, 206, 168))
  assert_true(highlight("#|literal")[0].style.fg is Rgb(206, 145, 120))
  assert_true(highlight("/// doc")[0].style.fg is Rgb(106, 153, 85))
}
