///|
/// Save a loaded editor version, or create a file that does not yet exist.
pub let fs_write_file : Command[
  @protocol.WriteFilePayload,
  @protocol.WriteFileReply,
] = Command("fs.write_file")
