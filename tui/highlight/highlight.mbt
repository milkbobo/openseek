///|
/// Select a terminal highlighter for MoonBit source, interface and script
/// files. The shared lexer is deliberately stateless across line boundaries,
/// so the editor can tokenize only visible source lines, including after edits
/// and scrolling. Token offsets and span lengths both use UTF-16 code units.
pub fn for_path(
  path : String,
  base~ : @tui.Style = @tui.Style(),
) -> ((String) -> Array[@tui.Span])? {
  guard path.has_suffix(".mbt") ||
    path.has_suffix(".mbti") ||
    path.has_suffix(".mbtx") else {
    return None
  }
  let tokenizer = @lang_moonbit.MoonBitTokenizer()
  Some(line => {
    let (tokens, _) = tokenizer.tokenize_line(line, tokenizer.initial_state())
    let spans : Array[@tui.Span] = []
    let mut at = 0
    for token in tokens {
      if at < token.start {
        spans.push(@tui.Span(line[at:token.start], style=base))
      }
      spans.push(
        @tui.Span(
          line[token.start:token.end],
          style=token_style(token.tag, base),
        ),
      )
      at = token.end
    }
    if at < line.length() {
      spans.push(@tui.Span(line[at:], style=base))
    }
    spans
  })
}

///|
fn token_style(tag : @syntax.HighlightTag, base : @tui.Style) -> @tui.Style {
  @tui.Style(
    fg=match tag {
      Keyword => Rgb(86, 156, 214)
      Type | Tag => Rgb(78, 201, 176)
      Function => Rgb(220, 220, 170)
      String | Regexp => Rgb(206, 145, 120)
      Number | Constant => Rgb(181, 206, 168)
      Comment | CommentDoc => Rgb(106, 153, 85)
      StringEscape | Attribute => Rgb(215, 186, 125)
      Invalid => Rgb(255, 136, 145)
      Identifier | Variable | Plain | Punctuation | Operator | Delimiter =>
        base.fg
    },
    bg=base.bg,
    bold=base.bold,
    italic=base.italic,
    underline=base.underline,
    reverse=base.reverse,
  )
}
