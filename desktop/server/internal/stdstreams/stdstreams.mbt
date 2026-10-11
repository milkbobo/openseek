// A server that talks to its one client over its own standard streams has a
// problem every child process shares: a child started without explicit
// streams inherits descriptors 0 and 1, so a single `git` or `xdg-open` could
// swallow a request or print into the middle of a response. Auditing every
// launch would hold only until the next one is written. Instead the channel
// moves away before anything is started: the process keeps private,
// close-on-exec copies, and what children inherit is the null device and
// standard error.

///|
/// The channel that arrived on standard input and output.
pub struct Streams {
  input : @raw_fd.RawFdStream
  output : @raw_fd.RawFdStream
}

///|
/// The standard streams could not be taken over; `errno` says why.
pub suberror ClaimError {
  ClaimError(errno~ : Int)
}

///|
/// Take the channel off descriptors 0 and 1. From here on this process's
/// standard input reads as empty and its standard output is its standard
/// error, for itself and for every process it starts. Call it once, before
/// anything is spawned.
pub async fn claim() -> Streams {
  let descriptors : FixedArray[Int] = [0, 0]
  let errno = claim_standard_streams(descriptors)
  guard errno == 0 else { raise ClaimError(errno~) }
  { input: RawFdStream(descriptors[0]), output: RawFdStream(descriptors[1]), }
}

///|
#borrow(descriptors)
extern "c" fn claim_standard_streams(descriptors : FixedArray[Int]) -> Int = "moonbit_openseek_desktop_server_claim_standard_streams"
