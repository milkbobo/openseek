///|
/// A fictional offline workspace for repeatable terminal layout previews.
pub fn State::set_demo(self : State, diff~ : Bool = false) -> Unit {
  let root = "/workspace/seekmoon"
  let context : @workbench.Context = {
    session: "demo-session",
    workspace: Some(root),
    model: "deepseek-flash",
    run_id: None,
    archived: false,
  }
  let original = "///|\nfn greeting(name : String) -> String {\n  \"Hello, \" + name\n}\n\n///|\nfn main {\n  println(greeting(\"MoonBit\"))\n}\n"
  let source = "///|\nfn greeting(name : String) -> String {\n  \"Welcome, \" + name + \" 🌙\"\n}\n\n///|\nfn main {\n  let message = greeting(\"SeekMoon\")\n  println(message)\n}\n"
  self.tabs.clear()
  let editor = @editor.Editor(text=source, preserve_text=true)
  editor.move_to_start()
  let baseline = @editor.Editor(text=original, preserve_text=true)
  baseline.move_to_start()
  self.tabs.push({
    path: root + "/src/main.mbt",
    root,
    context,
    editor,
    original: baseline,
    baseline: Some(original),
    external_changed: false,
    diff,
    unified: false,
    diff_scroll: @tui.Scroll(),
    undo: [],
    redo: [],
  })
  self.active = 0
  self.root = Some(root)
  self.context = Some(context)
  self.tree = [
    { path: root + "/src", name: "src", depth: 0, is_dir: true, },
    { path: root + "/src/main.mbt", name: "main.mbt", depth: 1, is_dir: false, },
    { path: root + "/src/moon.pkg", name: "moon.pkg", depth: 1, is_dir: false, },
    { path: root + "/tests", name: "tests", depth: 0, is_dir: true, },
    { path: root + "/moon.mod", name: "moon.mod", depth: 0, is_dir: false, },
    { path: root + "/README.md", name: "README.md", depth: 0, is_dir: false, },
  ]
  self.selected = 1
  self.top = 0
  self.message = if diff {
    "Git diff · Ctrl+D unified/edit · Ctrl+S save"
  } else {
    "main.mbt · Ctrl+S save · Ctrl+Z undo"
  }
}
