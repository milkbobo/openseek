// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend PageCellWide with Eq::{not_equal, equal}

///|
pub extend PageCellWide with @debug.Debug::{to_repr}

///|
pub extend PageRowState with Eq::{not_equal, equal}

///|
pub extend PageRowState with @debug.Debug::{to_repr}

///|
pub extend PageCellFlags with Eq::{not_equal, equal}

///|
pub extend PageCellFlags with @debug.Debug::{to_repr}

///|
pub extend PageCellState with Eq::{not_equal, equal}

///|
pub extend PageCellState with @debug.Debug::{to_repr}

///|
pub extend GraphemeId with Eq::{not_equal, equal}

///|
pub extend GraphemeId with @debug.Debug::{to_repr}

///|
pub extend GraphemeId with Hash::{hash, hash_combine}

///|
pub extend SemanticContent with Eq::{not_equal, equal}

///|
pub extend SemanticContent with @debug.Debug::{to_repr}

///|
pub extend RowSemanticPrompt with Eq::{not_equal, equal}

///|
pub extend RowSemanticPrompt with @debug.Debug::{to_repr}
