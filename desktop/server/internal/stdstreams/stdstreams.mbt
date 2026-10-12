// A server that talks to its one client over its own standard streams has a
// problem every child process shares: a child started without explicit
// streams inherits descriptors 0 and 1, so a single `git` or `xdg-open` could
// swallow a request or print into the middle of a response. Auditing every
// launch would hold only until the next one is written. Instead the channel
// moves away before anything is started: the process keeps private,
// close-on-exec copies, and what children inherit is the null device and
// standard error.

///|
/// The standard streams could not be taken over; `errno` says why.
#cfg(not(platform="windows"))
pub suberror ClaimError {
  ClaimError(errno~ : Int)
}

///|
/// This platform has no descriptors to move the channel to: the server does
/// not run on Windows.
#cfg(platform="windows")
pub suberror Unsupported {
  Unsupported
}

///|
/// Take the channel off descriptors 0 and 1 and return it as `(input,
/// output)`. From here on this process's standard input reads as empty and
/// its standard output is its standard error, for itself and for every
/// process it starts. Call it once, before anything is spawned.
#cfg(not(platform="windows"))
pub async fn claim() -> (@raw_fd.RawFdStream, @raw_fd.RawFdStream) {
  let descriptors : FixedArray[Int] = [0, 0]
  let errno = claim_standard_streams(descriptors)
  guard errno == 0 else { raise ClaimError(errno~) }
  (RawFdStream(descriptors[0]), RawFdStream(descriptors[1]))
}

///|
/// A stream there is built on a handle, not on a descriptor number, and the
/// moves this relies on have no counterpart; the server refuses to start
/// rather than serve on streams its children would share.
#cfg(platform="windows")
pub fn claim() -> (@raw_fd.RawFdStream, @raw_fd.RawFdStream) raise Unsupported {
  raise Unsupported
}

///|
#cfg(not(platform="windows"))
#borrow(descriptors)
extern "c" fn claim_standard_streams(descriptors : FixedArray[Int]) -> Int = "moonbit_openseek_desktop_server_claim_standard_streams"
