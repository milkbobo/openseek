///|
pub async fn read_marker(reader : &@io.Reader, marker : String) -> Bool {
  let pattern = @utf8.encode(marker + "\n")
  let prefixes = Array::make(pattern.length(), 0)
  let mut matched = 0
  for i = 1; i < pattern.length(); i = i + 1 {
    while matched > 0 && pattern[i] != pattern[matched] {
      matched = prefixes[matched - 1]
    }
    if pattern[i] == pattern[matched] {
      matched += 1
    }
    prefixes[i] = matched
  }
  matched = 0
  for _count = 0; _count < 65536; _count = _count + 1 {
    let byte = reader.read_exactly(1)[0]
    while matched > 0 && byte != pattern[matched] {
      matched = prefixes[matched - 1]
    }
    if byte == pattern[matched] {
      matched += 1
      if matched == pattern.length() {
        return true
      }
    }
  }
  false
}
