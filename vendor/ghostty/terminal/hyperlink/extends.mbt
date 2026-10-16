// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend CellHyperlink with Eq::{not_equal, equal}

///|
pub extend CellHyperlink with @debug.Debug::{to_repr}

///|
pub extend CellHyperlink with Hash::{hash, hash_combine}

///|
pub extend HyperlinkId with Eq::{not_equal, equal}

///|
pub extend HyperlinkId with @debug.Debug::{to_repr}

///|
pub extend HyperlinkId with Hash::{hash, hash_combine}
