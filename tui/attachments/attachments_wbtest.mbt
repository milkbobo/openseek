///|
test "file mentions match desktop encoding and cannot escape their attributes" {
  let draft : Draft = {
    images: [],
    files: [{ path: "a\"&<>\n月.pdf", source_root: "/project", }],
  }
  assert_eq(
    draft.prompt("  inspect it  "),
    "inspect it\n\n<user_mentions>\n<file path=\"a&quot;&amp;&lt;&gt;&#10;月.pdf\"/>\n</user_mentions>",
  )
  assert_eq(
    draft.prompt(""),
    "<user_mentions>\n<file path=\"a&quot;&amp;&lt;&gt;&#10;月.pdf\"/>\n</user_mentions>",
  )
}

///|
test "staging copies only imported originals and keeps source roots" {
  let draft : Draft = {
    images: [{ name: "image.png", url: "data:image/png;base64,AA==", }],
    files: [
      { path: "docs/normal.pdf", source_root: "/project", },
      { path: ".openseek/attachments/a/report.pdf", source_root: "/project", },
      { path: ".openseek/attachments/a/report.pdf", source_root: "/project", },
      {
        path: ".openseek/attachments/b/table.xlsx",
        source_root: "/previous-checkout",
      },
    ],
  }
  let payloads = draft.stage_payloads("conversation", "/project")
  assert_eq(payloads.length(), 2)
  for payload in payloads {
    assert_eq(payload.session, "conversation")
    assert_eq(payload.workspace, "/project")
    assert_eq(payload.paths.length(), 1)
    assert_true(!payload.paths.contains("docs/normal.pdf"))
    if payload.source_root == "/project" {
      assert_eq(payload.paths, [".openseek/attachments/a/report.pdf"])
    } else {
      assert_eq(payload.source_root, "/previous-checkout")
      assert_eq(payload.paths, [".openseek/attachments/b/table.xlsx"])
    }
  }
}

///|
test "draft removal, labels and consumption preserve the other attachments" {
  let draft : Draft = {
    images: [{ name: "moon.png", url: "data:image/png;base64,AA==", }],
    files: [{ path: "docs/report.pdf", source_root: "/project", }],
  }
  assert_eq(draft.labels(), ["Image · moon.png", "File · docs/report.pdf"])
  assert_true(draft.remove(0))
  assert_eq(draft.labels(), ["File · docs/report.pdf"])
  assert_true(!draft.remove(4))
  assert_true(!draft.is_empty())
  draft.clear()
  assert_true(draft.is_empty())
}

///|
test "submitted attachment snapshots retain original paths and prepend newer context" {
  let draft : Draft = {
    images: [{ name: "original.png", url: "data:image/png;base64,AA==", }],
    files: [
      { path: ".openseek/attachments/a/source.pdf", source_root: "/original", },
    ],
  }
  let submitted = draft.copy()
  assert_eq(submitted.copy_images().labels(), ["Image · original.png"])
  assert_eq(submitted.copy_images().image_urls(), ["data:image/png;base64,AA=="])
  draft.clear()
  draft.images.push({ name: "newer.png", url: "data:image/png;base64,AQ==", })
  draft.files.push({ path: "newer.pdf", source_root: "/newer", })
  draft.prepend(submitted)
  assert_eq(draft.labels(), [
    "Image · original.png", "Image · newer.png", "File · .openseek/attachments/a/source.pdf",
    "File · newer.pdf",
  ])
  let payloads = draft.stage_payloads("chat", "/project")
  assert_eq(payloads.length(), 1)
  assert_eq(payloads[0].source_root, "/original")
  assert_eq(submitted.labels(), [
    "Image · original.png", "File · .openseek/attachments/a/source.pdf",
  ])
}
