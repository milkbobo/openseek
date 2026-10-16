name = "moonbitlang/seekmoon_tui"

version = "0.1.0"

import {
  "moonbitlang/async@0.22.4",
  "moonbit-community/tui@0.1.0",
  "moonbit-community/tty@0.5.0",
  "moonbit-community/pty@0.4.3",
  "moonbit-community/moondiff@0.0.10",
  "tonyfettes/ghostty@0.5.1",
  "moonbitlang/openseek_protocol@0.3.1",
  "openseek_desktop@0.1.5",
  "openseek_desktop/server@0.1.5",
}

license = "Apache-2.0"

description = "SeekMoon terminal client for the shared desktop server."

preferred_target = "native"

supported_targets = "native"

warnings = "+implicit_impl_as_method+test_unqualified_package"
