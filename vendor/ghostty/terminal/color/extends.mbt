// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend ColorParseError with Eq::{not_equal, equal}

///|
pub extend ColorParseError with @debug.Debug::{to_repr}

///|
pub extend RGB with Eq::{not_equal, equal}

///|
pub extend RGB with @debug.Debug::{to_repr}

///|
pub extend Name with Eq::{not_equal, equal}

///|
pub extend Name with @debug.Debug::{to_repr}

///|
pub extend Special with Eq::{not_equal, equal}

///|
pub extend Special with @debug.Debug::{to_repr}

///|
pub extend Dynamic with Eq::{not_equal, equal}

///|
pub extend Dynamic with @debug.Debug::{to_repr}

///|
pub extend DynamicRGB with Eq::{not_equal, equal}

///|
pub extend DynamicRGB with @debug.Debug::{to_repr}

///|
pub extend DynamicPalette with Eq::{not_equal, equal}

///|
pub extend DynamicPalette with @debug.Debug::{to_repr}

///|
pub extend TerminalColors with Eq::{not_equal, equal}

///|
pub extend TerminalColors with @debug.Debug::{to_repr}
