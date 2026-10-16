///|
fn source_lines(text : String) -> Array[String] {
  text.split("\n").map(line => line.to_owned()).collect()
}

///|
fn diff_document(
  original : String,
  modified : String,
) -> @diff_model.HunkDocument {
  @linediff.line_diff(
    old=source_lines(original),
    new=source_lines(modified),
    context=3,
  )
}

///|
fn changed_lines(
  document : @diff_model.HunkDocument,
) -> (Map[Int32, Unit], Map[Int32, Unit]) {
  let removed : Map[Int32, Unit] = Map([])
  let added : Map[Int32, Unit] = Map([])
  for hunk in document.hunks {
    for block in hunk.blocks {
      match block {
        ContextBlock(_) | IgnoredBlock(_) => ()
        ChangeBlock(rows) =>
          for row in rows {
            match row {
              Paired(old, new) => {
                removed[old.index] = ()
                added[new.index] = ()
              }
              OldOnly(old) => removed[old.index] = ()
              NewOnly(new) => added[new.index] = ()
            }
          }
      }
    }
  }
  (removed, added)
}

///|
fn unified_lines(
  original : String,
  modified : String,
  path~ : String = "",
) -> Array[@tui.Line] {
  let document = diff_document(original, modified)
  let lines = @unified.render_unified_hunks(document)
  if lines.is_empty() {
    return [
      @tui.Line::from_text(
        "No changes from the task baseline.",
        style=@tui.Style(fg=Rgb(139, 151, 171)),
      ),
    ]
  }
  lines.map(line => {
    let style = if line.has_prefix("+") {
      @tui.Style(fg=Rgb(139, 222, 173), bg=Rgb(20, 45, 32))
    } else if line.has_prefix("-") {
      @tui.Style(fg=Rgb(241, 164, 166), bg=Rgb(48, 27, 32))
    } else if line.has_prefix("@@") {
      @tui.Style(fg=Rgb(117, 185, 239), bg=Rgb(26, 36, 50))
    } else {
      @tui.Style()
    }
    if (line.has_prefix("+") || line.has_prefix("-") || line.has_prefix(" ")) &&
      @highlight.for_path(path, base=style) is Some(highlight) {
      @tui.Line([@tui.Span(line[:1], style~), ..highlight(line[1:].to_owned())])
    } else {
      @tui.Line::from_text(line, style~)
    }
  })
}

///|
fn Tab::draw_diff(
  self : Tab,
  frame : @tui.Frame,
  area : @tui.Rect,
  focused : Bool,
) -> Unit {
  let original = self.original.text()
  let modified = self.editor.text()
  if self.unified {
    frame.lines(
      area,
      unified_lines(original, modified, path=self.path),
      scroll=self.diff_scroll,
    )
    return
  }
  if area.width < 60 {
    self.editor.draw(
      frame,
      area,
      focused~,
      highlight?=@highlight.for_path(self.path),
      line_numbers=@tui.Style(fg=Rgb(116, 131, 150)),
    )
    return
  }
  guard @tui.Layout::horizontal([Fill(1), Length(1), Fill(1)]).split(area)
    is [old_area, separator, new_area] else {
    return
  }
  let (removed, added) = changed_lines(diff_document(original, modified))
  let label_style = @tui.Style(fg=Rgb(143, 157, 178), bg=Rgb(28, 36, 49))
  frame.line(old_area, @tui.Line::from_text(" Original", style=label_style))
  frame.line(
    new_area,
    @tui.Line::from_text(" Working tree · editable", style=label_style),
  )
  for row in 0..<separator.height {
    frame.text(
      row=separator.row + row,
      col=separator.col,
      "│",
      style=@tui.Style(fg=Rgb(48, 60, 79)),
    )
  }
  let old_body = @tui.Rect(
    row=old_area.row + 1,
    col=old_area.col,
    width=old_area.width,
    height=(old_area.height - 1).max(0),
  )
  let new_body = @tui.Rect(
    row=new_area.row + 1,
    col=new_area.col,
    width=new_area.width,
    height=(new_area.height - 1).max(0),
  )
  self.original.draw(
    frame,
    old_body,
    focused=false,
    highlight?=@highlight.for_path(self.path),
    line_numbers=@tui.Style(fg=Rgb(116, 131, 150)),
    line_style=line => {
      if removed.contains(line) {
        @tui.Style(fg=Rgb(241, 164, 166), bg=Rgb(48, 27, 32))
      } else {
        @tui.Style()
      }
    },
  )
  self.editor.draw(
    frame,
    new_body,
    focused~,
    highlight?=@highlight.for_path(self.path),
    line_numbers=@tui.Style(fg=Rgb(116, 131, 150)),
    line_style=line => {
      if added.contains(line) {
        @tui.Style(fg=Rgb(139, 222, 173), bg=Rgb(20, 45, 32))
      } else {
        @tui.Style()
      }
    },
  )
}
