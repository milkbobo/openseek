///|
test "update download progress labels known and unknown totals" {
  let known : Progress = {
    downloaded_bytes: 50 * 1024 * 1024,
    total_bytes: Some(100 * 1024 * 1024),
  }
  assert_eq(known.percentage(), Some(50))
  assert_eq(known.sidebar_label(), "Downloading 50%")
  assert_eq(
    known.status_text("0.2.0"),
    "Downloading 0.2.0… 50% (50 / 100 MB)",
  )
  let unknown : Progress = {
    downloaded_bytes: 3 * 1024 * 1024,
    total_bytes: None,
  }
  assert_eq(unknown.percentage(), None)
  assert_eq(unknown.sidebar_label(), "Downloading…")
  assert_eq(unknown.status_text("0.2.0"), "Downloading 0.2.0… 3 MB")
}
