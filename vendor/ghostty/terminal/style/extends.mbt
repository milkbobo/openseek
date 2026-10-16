// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend StyleColor with Eq::{not_equal, equal}

///|
pub extend StyleColor with @debug.Debug::{to_repr}

///|
pub extend StyleColor with Hash::{hash, hash_combine}

///|
pub extend CellStyle with Eq::{not_equal, equal}

///|
pub extend CellStyle with @debug.Debug::{to_repr}

///|
pub extend CellStyle with Hash::{hash, hash_combine}

///|
pub extend StyleId with Eq::{not_equal, equal}

///|
pub extend StyleId with @debug.Debug::{to_repr}

///|
pub extend StyleId with Hash::{hash, hash_combine}
