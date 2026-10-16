///|
/// Offline page data used by the TUI preview and rendering tests.
pub fn State::set_demo(self : State, page : Page) -> Unit {
  self.page = Some(page)
  self.focus = 0
  self.page_offset = 0
  self.notice = ""
  self.form = None
  self.installed = [
    {
      id: "review",
      name: "Code review",
      description: "Review changes for correctness and maintainability.",
      source: "examples/engineering@1.0.0",
      registry: Some({
        module_name: "examples/engineering",
        package_path: "review",
      }),
    },
    {
      id: "project-guide",
      name: "Project guide",
      description: "Conventions and local development workflow.",
      source: "",
      registry: None,
    },
  ]
  self.catalog = [
    {
      name: "Code review",
      module_name: "examples/engineering",
      package_path: "review",
      version: "1.0.0",
      description: "Review changes for correctness and maintainability.",
      author: "Example",
      repository: "https://example.com/skills",
    },
    {
      name: "Release notes",
      module_name: "examples/writing",
      package_path: "release",
      version: "1.0.0",
      description: "Write release notes from a set of changes.",
      author: "Example",
      repository: "https://example.com/skills",
    },
  ]
  self.settings = Some({
    revision: 1,
    provider: "deepseek",
    custom_api_url: None,
    has_deepseek_key: true,
    has_glm_key: false,
    has_custom_key: false,
    followup_behavior: "steer",
  })
  self.provider = 0
  self.settings_dirty = false
  self.queue = false
  self.url.clear()
  self.key.clear()
  self.snapshot = {
    entries: [
      {
        id: "daily-review",
        spec: {
          name: "Review the workspace",
          workspace: Some("/workspace/example"),
          task: "Check recent changes, run the tests, and summarize any failures.",
          model: None,
          timing: Every(60),
          timeout_minutes: 30,
        },
        enabled: true,
        run_requested: false,
        notice: None,
        next_at: None,
      },
      {
        id: "release-notes",
        spec: {
          name: "Prepare release notes",
          workspace: Some("/workspace/example"),
          task: "Draft concise release notes for the next release.",
          model: None,
          timing: Every(1440),
          timeout_minutes: 30,
        },
        enabled: false,
        run_requested: false,
        notice: None,
        next_at: None,
      },
    ],
    runs: [
      {
        id: "run-example",
        schedule_id: "daily-review",
        name: "Review the workspace",
        workspace: "/workspace/example",
        session: "review-example",
        started_at: 0L,
        finished_at: Some(1000L),
        status: Succeeded,
        log_path: "/workspace/example/run.log",
      },
    ],
  }
}
