///|
/// Commands are grouped by the same workflows as the desktop navigation.
pub fn help() -> Array[String] {
  [
    "PROJECTS", "/workspaces · /workspace PATH · /workspace add|remove PATH", "/worktree list|create|repair|remove NAME [--force]",
    "/workspace-settings [worktrees|submodules on|off] [timeout SECONDS]", "FILES AND CODE",
    "/files [PATH] · /browse [PATH] · /mkdir NAME · /file PATH · /attach PATH · /upload LOCAL_PATH · /attachments · /detach NUMBER",
    "/find QUERY · /grep QUERY [--regex] [--case] [--word] [--include GLOB] [--exclude GLOB]",
    "/semantic 'PATTERN' [--include GLOB] [--exclude GLOB]", "/definition PATH LINE COLUMN · /references PATH LINE COLUMN",
    "/symbols QUERY · /hover PATH LINE COLUMN · /diagnostics PATH · /packages [moon.mod]",
    "REVIEW", "/git changes|branch [BASE]|pr|commit REVISION|original PATH [REVISION]",
    "/diff PATH [REVISION] · /history [OFFSET]", "/github pulls|all|issues|review|checkout-status",
    "/github pr REPOSITORY_URL NUMBER · /github file PATH BASE HEAD", "/github checkout REPOSITORY_URL NUMBER [ask|stash|discard|carry] [--update]",
    "/github post PR_URL PATH LINE HEAD BODY · /github reply PR_URL COMMENT_ID BODY",
    "/github delete PR_URL COMMENT_ID · /github resolve|reopen PR_URL THREAD_ID",
    "/github drafts PR_URL", "JOBS AND SCHEDULES", "/jobs [list OFFSET]|read GENERATION ID [OFFSET]|stop GENERATION ID",
    "/schedules · /schedule every MINUTES 'NAME' 'TASK'", "/schedule once UNIX_MS 'NAME' 'TASK' · /schedule pause|resume|run|stop|delete ID",
    "SKILLS", "/skills [installed|catalog] · /skills read ID · /skills remove ID",
    "/skills show|install MODULE VERSION [PACKAGE]", "SETTINGS", "/settings · /provider deepseek|glm|openrouter|custom [URL]",
    "/key deepseek|glm|custom KEY · /followup steer|queue", "/auth [status|connect|cancel|disconnect]",
    "CODEX", "/mode codex|openseek · /codex list|new|open THREAD_ID · /codex threads|archived [CURSOR]",
    "/codex read|history|compact|review THREAD_ID · /codex resume THREAD_ID [ask|auto|full]",
    "/codex rename THREAD_ID NAME · /codex archive THREAD_ID [--force] · /codex unarchive THREAD_ID",
    "/codex send THREAD_ID TEXT · /codex steer THREAD_ID TURN_ID TEXT", "/codex interrupt THREAD_ID TURN_ID · /codex requests · /codex approve|deny TOKEN",
    "/codex respond TOKEN RESULT_JSON", "/codex status|models|account|login|logout|config · /codex cancel-login LOGIN_ID",
    "/codex skills THREAD_ID", "Quote paths or text containing spaces. Terminal tabs support full-screen programs and $EDITOR.",
  ]
}
