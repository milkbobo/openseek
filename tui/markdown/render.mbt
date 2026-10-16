///|
/// Render CommonMark and table/task-list extensions as terminal cells.
/// Width is measured in display columns, including CJK and emoji graphemes.
pub fn render(
  text : String,
  width : Int32,
  dim~ : Bool = false,
) -> Array[@tui.Line] {
  let doc = @cmark.Doc::from_string(text, strict=false)
  let renderer = Renderer::{ defs: doc.defs, dim, }
  renderer.block(doc.block, width.max(1))
}

///|
priv struct Renderer {
  defs : Map[String, @cmark.LabelDef]
  dim : Bool
}

///|
fn Renderer::base(self : Renderer) -> @tui.Style {
  if self.dim {
    muted()
  } else {
    @tui.Style()
  }
}

///|
fn muted() -> @tui.Style {
  @tui.Style(fg=Rgb(133, 148, 169))
}

///|
fn Renderer::heading(self : Renderer) -> @tui.Style {
  restyle(self.base(), fg=Rgb(118, 194, 255), bold=true)
}

///|
fn Renderer::code_style(self : Renderer, style : @tui.Style) -> @tui.Style {
  restyle(
    style,
    fg=if self.dim { muted().fg } else { Rgb(210, 200, 166) },
    bg=Rgb(25, 31, 41),
  )
}

///|
fn Renderer::inline(
  self : Renderer,
  inline : @cmark.Inline,
  style : @tui.Style,
  lines : Array[Array[@tui.Span]],
) -> Unit {
  let push = fn(text : String, style : @tui.Style) {
    lines[lines.length() - 1].push(@tui.Span(text, style~))
  }
  match inline {
    Text(node) => push(node.v, style)
    Inlines(node) =>
      for child in node.v.iter() {
        self.inline(child, style, lines)
      }
    StrongEmphasis(node) =>
      self.inline(node.v.inline, restyle(style, bold=true), lines)
    Emphasis(node) =>
      self.inline(node.v.inline, restyle(style, italic=true), lines)
    CodeSpan(node) => push(node.v.code(), self.code_style(style))
    Break(node) =>
      if node.v.ty is Hard {
        lines.push([])
      } else {
        push(" ", style)
      }
    Link(node) | Image(node) => {
      if inline is Image(_) {
        push("Image: ", muted())
      }
      self.inline(
        node.v.text,
        restyle(style, fg=Rgb(118, 194, 255), underline=true),
        lines,
      )
      if node.v.reference_definition(self.defs) is Some(LinkDef(def)) &&
        def.v.dest is Some(dest) {
        let label = node.v.text
          .to_plain_text(break_on_soft=false)
          .iter()
          .flat_map(parts => parts.iter())
          .collect()
          .join("")
        if dest.v != label && !dest.v.is_empty() {
          push(" (\{dest.v})", muted())
        }
      }
    }
    Autolink(node) =>
      push(node.v.link.v, restyle(style, fg=Rgb(118, 194, 255), underline=true))
    ExtStrikethrough(node) =>
      self.inline(node.v.0, restyle(style, fg=muted().fg), lines)
    ExtMathSpan(node) => push(node.v.tex(), self.code_style(style))
    RawHtml(node) =>
      for tight in node.v.0.iter() {
        push(tight.to_string(), style)
      }
  }
}

///|
fn Renderer::inline_lines(
  self : Renderer,
  inline : @cmark.Inline,
  style : @tui.Style,
) -> Array[@tui.Line] {
  let lines : Array[Array[@tui.Span]] = [[]]
  self.inline(inline, style, lines)
  lines.map(spans => @tui.Line(spans))
}

///|
fn prefixed(
  lines : Array[@tui.Line],
  first : String,
  rest : String,
  width : Int32,
) -> Array[@tui.Line] {
  lines.mapi((i, line) => {
    let prefix = @tui.Line::from_text(
      if i == 0 {
        first
      } else {
        rest
      },
      style=muted(),
    )
    if prefix.width() >= width {
      line
    } else {
      prefix.concat(line)
    }
  })
}

///|
fn inset(width : Int32, prefix : String) -> Int32 {
  let size = @tui.Line::from_text(prefix).width()
  if size >= width {
    width
  } else {
    width - size
  }
}

///|
fn Renderer::block(
  self : Renderer,
  block : @cmark.Block,
  width : Int32,
) -> Array[@tui.Line] {
  match block {
    Blocks(node) => {
      let lines : Array[@tui.Line] = []
      for child in node.v.iter() {
        let rendered = self.block(child, width)
        if !rendered.is_empty() {
          if !lines.is_empty() {
            lines.push(@tui.Line([]))
          }
          lines.append(rendered)
        }
      }
      lines
    }
    Paragraph(node) =>
      self
      .inline_lines(node.v.inline, self.base())
      .iter()
      .flat_map(line => line.wrap(width).iter())
      .collect()
    Heading(node) =>
      self
      .inline_lines(node.v.inline, self.heading())
      .iter()
      .flat_map(line => line.wrap(width).iter())
      .collect()
    BlockQuote(node) =>
      prefixed(
        self.block(node.v.block, inset(width, "│ ")),
        "│ ",
        "│ ",
        width,
      )
    List(node) => {
      let lines : Array[@tui.Line] = []
      let mut number = match node.v.ty {
        Unordered(_) => 0
        Ordered(start, _) => start
      }
      for item in node.v.items.iter() {
        let marker = if item.v.ext_task_marker is Some(task) {
          if task.v == ' ' {
            "☐ "
          } else {
            "☑ "
          }
        } else if node.v.ty is Ordered(_, _) {
          "\{number}. "
        } else {
          "• "
        }
        number += 1
        let content = self.block(item.v.block, inset(width, marker))
        if !node.v.tight && !lines.is_empty() {
          lines.push(@tui.Line([]))
        }
        lines.append(
          prefixed(
            content,
            marker,
            " ".repeat(@tui.Line::from_text(marker).width()),
            width,
          ),
        )
      }
      lines
    }
    CodeBlock(node) | ExtMathBlock(node) => {
      let lines : Array[@tui.Line] = []
      if node.v.info_string is Some(info) && !info.v.is_empty() {
        lines.append(@tui.Line::from_text(info.v, style=muted()).wrap(width))
      }
      for code in node.v.code.iter() {
        let line = @tui.Line::from_text(
          code.v.replace(old="\t", new="    "),
          style=self.code_style(self.base()),
        )
        lines.append(
          prefixed(line.wrap(inset(width, "│ ")), "│ ", "│ ", width),
        )
      }
      lines
    }
    ExtTable(node) => self.table(node.v, width)
    ThematicBreak(_) =>
      [@tui.Line::from_text("─".repeat(width.min(40)), style=muted())]
    HtmlBlock(node) =>
      node.v.0
      .iter()
      .flat_map(line => {
        @tui.Line::from_text(line.v, style=self.base()).wrap(width).iter()
      })
      .collect()
    ExtFootnoteDefinition(node) =>
      prefixed(
        self.block(node.v.block, inset(width, "↳ ")),
        "↳ ",
        "  ",
        width,
      )
    BlankLine(_) | LinkRefDefinition(_) => []
  }
}

///|
fn restyle(
  style : @tui.Style,
  fg~ : @color.Color = style.fg,
  bg~ : @color.Color = style.bg,
  bold~ : Bool = style.bold,
  italic~ : Bool = style.italic,
  underline~ : Bool = style.underline,
) -> @tui.Style {
  @tui.Style(fg~, bg~, bold~, italic~, underline~, reverse=style.reverse)
}
