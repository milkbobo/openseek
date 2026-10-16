// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend Slots with Eq::{not_equal, equal}

///|
pub extend Slots with @debug.Debug::{to_repr}

///|
pub extend ActiveSlot with Eq::{not_equal, equal}

///|
pub extend ActiveSlot with @debug.Debug::{to_repr}

///|
pub extend Charset with Eq::{not_equal, equal}

///|
pub extend Charset with @debug.Debug::{to_repr}
