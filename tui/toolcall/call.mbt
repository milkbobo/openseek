///|
pub(all) enum Status {
  Pending
  Succeeded
  Failed
  Interrupted
} derive(Eq)

///|
/// Immutable presentation of one call. Retain the identity and full payloads
/// for expansion; captions never contain raw output or serialized arguments.
pub struct Call {
  id : String
  name : String
  arguments : String?
  output : String?
  caption : String
  status : Status
} derive(Eq)

///|
pub fn Call::Call(
  id : String,
  name : String,
  arguments? : String,
  output? : String,
  brief? : String,
  status~ : Status = Pending,
) -> Call {
  let description = arguments.bind(description)
  let caption = if name == "mbtx" && description is Some(text) {
    text
  } else if name != "shell" && brief is Some(text) && !text.is_blank() {
    text
  } else {
    description.unwrap_or("")
  }
  { id, name, arguments, output, caption: single_line(caption), status, }
}

///|
fn description(arguments : String) -> String? {
  // Like the desktop, bound caption parsing: large scripts must not make a
  // collapsed row expensive to prepare.
  guard arguments.length() <= 65536 else { return None }
  let json = @json.parse(arguments) catch { _ => return None }
  if json is { "description": String(text), .. } && !text.is_blank() {
    Some(text)
  } else {
    None
  }
}

///|
fn single_line(text : String) -> String {
  text.split("\n").map(line => line.trim().to_owned()).join(" ")
}

///|
pub fn Call::finish(
  self : Call,
  output : String,
  brief? : String,
  status~ : Status,
) -> Call {
  Call(self.id, self.name, arguments?=self.arguments, output~, brief?, status~)
}

///|
pub fn Call::interrupt(self : Call) -> Call {
  if self.status is Pending {
    { ..self, status: Interrupted, }
  } else {
    self
  }
}

///|
pub fn Call::lines(
  self : Call,
  width : Int32,
  expanded~ : Bool = false,
  selected~ : Bool = false,
) -> Array[@tui.Line] {
  let status = match self.status {
    Pending => "…"
    Succeeded => "✓"
    Failed => "✗"
    Interrupted => "–"
  }
  let arrow = if expanded { "▾" } else { "▸" }
  let caption = if self.caption.is_empty() { "" } else { " · " + self.caption }
  let style = @tui.Style(
    fg=if self.status is Failed {
      Rgb(255, 136, 145)
    } else {
      Rgb(133, 148, 169)
    },
    bold=selected,
    reverse=selected,
  )
  // A header always occupies exactly one terminal row, even on narrow panes.
  let header = @tui.Line::from_text(
    "\{arrow} \{status} \{self.name}\{caption}",
    style~,
  )
  let header = if header.width() > width.max(1) {
    if width <= 1 {
      @tui.Line::from_text("…", style~)
    } else {
      header.wrap((width - 1).max(1))[0].concat(
        @tui.Line::from_text("…", style~),
      )
    }
  } else {
    header
  }
  let lines = [header]
  if expanded {
    for
      (label, body) in [("Arguments", self.arguments), ("Output", self.output)] {
      if body is Some(body) {
        lines.push(@tui.Line::from_text("  \{label}", style~))
        for raw in body.split("\n") {
          lines.append(
            @tui.Line::from_text(raw)
            .wrap((width - 2).max(1))
            .map(line => @tui.Line::from_text("  ").concat(line)),
          )
        }
      }
    }
    if self.output is None {
      lines.push(
        @tui.Line::from_text(
          if self.status is Pending {
            "  Running…"
          } else {
            "  No result recorded"
          },
          style~,
        ),
      )
    }
  }
  lines
}

///|
pub extend Status with Eq::{equal, not_equal}

///|
pub extend Call with Eq::{equal, not_equal}
