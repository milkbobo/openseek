///|
fn github(args : Array[String], context : Context) -> Plan raise InputError {
  let cwd = workspace(context)
  let action = args.get(1).unwrap_or("pulls")
  match action {
    "pulls" | "all" | "issues" => {
      let kind = match action {
        "pulls" => @protocol.CreatedByMe
        "issues" => @protocol.Issues
        _ => @protocol.AllOpen
      }
      request(
        @commands.github_list,
        { cwd, kind, limit: 100, },
        "GitHub · " + action,
      )
    }
    "pr" =>
      request(
        @commands.github_pull_request,
        {
          cwd,
          repository_url: arg(args, 2, "/github pr REPOSITORY_URL NUMBER"),
          number: positive(
            arg(args, 3, "/github pr REPOSITORY_URL NUMBER"),
            "Pull request number",
          ),
        },
        "Pull request",
      )
    "review" =>
      request(@commands.github_review, { cwd, }, "Pull request review")
    "file" =>
      request(
        @commands.github_review_file,
        {
          cwd,
          path: arg(args, 2, "/github file PATH BASE HEAD"),
          base: arg(args, 3, "/github file PATH BASE HEAD"),
          head: arg(args, 4, "/github file PATH BASE HEAD"),
        },
        "Pull request file",
      )
    "checkout-status" =>
      request(
        @commands.github_checkout_status,
        { cwd, },
        "Pull request checkout",
      )
    "checkout" => {
      let changes = match args.get(4).unwrap_or("ask") {
        "ask" => @protocol.Ask
        "stash" => @protocol.Stash
        "discard" => @protocol.Discard
        "carry" => @protocol.Carry
        _ =>
          raise InputError(
            "Checkout changes action must be ask, stash, discard, or carry",
          )
      }
      request(
        @commands.github_checkout,
        {
          cwd,
          repository_url: arg(
            args, 2, "/github checkout REPOSITORY_URL NUMBER [ask|stash|discard|carry] [--update]",
          ),
          number: positive(
            arg(args, 3, "/github checkout REPOSITORY_URL NUMBER"),
            "Pull request number",
          ),
          changes,
          update: args.get(5) == Some("--update"),
        },
        "Pull request checked out",
        refresh=true,
      )
    }
    "drafts" =>
      request(
        @commands.github_drafts_get,
        { url: arg(args, 2, "/github drafts PR_URL"), },
        "Local review drafts",
      )
    "post" | "reply" | "delete" | "resolve" | "reopen" => {
      let url = arg(
        args, 2, "/github post|reply|delete|resolve|reopen PR_URL ...",
      )
      let action : @protocol.GithubReviewAction = match action {
        "post" =>
          @protocol.Post(
            path=arg(args, 3, "/github post PR_URL PATH LINE HEAD BODY"),
            side="RIGHT",
            line=positive(
              arg(args, 4, "/github post PR_URL PATH LINE HEAD BODY"),
              "Line",
            ),
            head=arg(args, 5, "/github post PR_URL PATH LINE HEAD BODY"),
            body=rest(args, 6, "/github post PR_URL PATH LINE HEAD BODY"),
          )
        "reply" =>
          @protocol.Reply(
            comment=arg(args, 3, "/github reply PR_URL COMMENT_ID BODY"),
            body=rest(args, 4, "/github reply PR_URL COMMENT_ID BODY"),
          )
        "delete" =>
          @protocol.Delete(
            comment=arg(args, 3, "/github delete PR_URL COMMENT_ID"),
          )
        _ =>
          @protocol.Resolve(
            thread=arg(args, 3, "/github resolve|reopen PR_URL THREAD_ID"),
            resolved=action == "resolve",
          )
      }
      request(
        @commands.github_review_mutate,
        { cwd, url, action, },
        "GitHub review updated",
      )
    }
    _ =>
      raise InputError(
        "Usage: /github pulls|all|issues|pr|review|file|checkout|checkout-status|drafts|post|reply|delete|resolve|reopen",
      )
  }
}
