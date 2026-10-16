// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend SgrUnderline with Eq::{not_equal, equal}

///|
pub extend SgrUnderline with @debug.Debug::{to_repr}

///|
pub extend SgrUnknown with Eq::{not_equal, equal}

///|
pub extend SgrUnknown with @debug.Debug::{to_repr}

///|
pub extend SgrAttribute with Eq::{not_equal, equal}

///|
pub extend SgrAttribute with @debug.Debug::{to_repr}

///|
pub extend SgrParser with @debug.Debug::{to_repr}
