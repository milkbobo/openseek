// Explicit trait method exports preserve upstream method lookup on current MoonBit.

///|
pub extend KeyAction with Eq::{not_equal, equal}

///|
pub extend KeyAction with @debug.Debug::{to_repr}

///|
pub extend KeyModSide with Eq::{not_equal, equal}

///|
pub extend KeyModSide with @debug.Debug::{to_repr}

///|
pub extend KeyMods with Eq::{not_equal, equal}

///|
pub extend KeyMods with @debug.Debug::{to_repr}

///|
pub extend Key with Eq::{not_equal, equal}

///|
pub extend Key with @debug.Debug::{to_repr}

///|
pub extend KeyEvent with Eq::{not_equal, equal}

///|
pub extend KeyEvent with @debug.Debug::{to_repr}

///|
pub extend MouseEvent with Eq::{not_equal, equal}

///|
pub extend MouseEvent with @debug.Debug::{to_repr}

///|
pub extend MouseFormat with Eq::{not_equal, equal}

///|
pub extend MouseFormat with @debug.Debug::{to_repr}

///|
pub extend MouseShape with Eq::{not_equal, equal}

///|
pub extend MouseShape with @debug.Debug::{to_repr}

///|
pub extend MouseAction with Eq::{not_equal, equal}

///|
pub extend MouseAction with @debug.Debug::{to_repr}

///|
pub extend MouseButton with Eq::{not_equal, equal}

///|
pub extend MouseButton with @debug.Debug::{to_repr}

///|
pub extend MousePosition with Eq::{not_equal, equal}

///|
pub extend MousePosition with @debug.Debug::{to_repr}

///|
pub extend MouseInputEvent with Eq::{not_equal, equal}

///|
pub extend MouseInputEvent with @debug.Debug::{to_repr}
