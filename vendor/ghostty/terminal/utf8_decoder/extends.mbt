// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend DecodeResult with Eq::{not_equal, equal}

///|
pub extend DecodeResult with @debug.Debug::{to_repr}

///|
pub extend Utf8Decoder with Eq::{not_equal, equal}

///|
pub extend Utf8Decoder with @debug.Debug::{to_repr}
