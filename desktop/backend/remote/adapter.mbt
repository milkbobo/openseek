///|
/// Transport type erasure happens after the service/desktop endpoint has
/// already paired a typed command and its handler. The registry is not rebuilt.
pub(all) struct RequestHandler {
  name : String
  invoke : async (Json) -> Json
}
