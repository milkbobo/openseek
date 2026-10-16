// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend TerminalResultCode with Eq::{not_equal, equal}

///|
pub extend TerminalResultCode with @debug.Debug::{to_repr}
