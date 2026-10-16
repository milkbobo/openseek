///|
pub(all) suberror SshError {
  SshError(String)
}

///|
/// Tokenize a connection command, never evaluate it as a shell program.
fn words(command : String) -> Array[String] raise {
  let words : Array[String] = []
  let mut word = ""
  let mut quote : Char? = None
  let mut escape = false
  let mut started = false
  for ch in command {
    if escape {
      word += ch.to_string()
      escape = false
      started = true
      continue
    }
    if ch == '\\' && quote != Some('\'') {
      escape = true
      continue
    }
    if quote is Some(q) {
      if ch == q {
        quote = None
      } else {
        word += ch.to_string()
      }
    } else if ch == '\'' || ch == '"' {
      quote = Some(ch)
      started = true
    } else if ch == ' ' || ch == '\t' {
      if started {
        words.push(word)
        word = ""
        started = false
      }
    } else {
      guard ch != '\n' && ch != '\r' else {
        raise SshError("Enter one SSH connection command")
      }
      word += ch.to_string()
      started = true
    }
  }
  guard !escape && quote is None else {
    raise SshError("Unclosed quote or escape in SSH command")
  }
  if started {
    words.push(word)
  }
  words
}

///|
/// Connection options only: remote commands, forwarding and terminal flags
/// would change the protocol's stdin/stdout ownership and are rejected.
pub fn arguments(command : String) -> Array[String] raise {
  let tokens = words(command)
  guard tokens.length() >= 2 && tokens[0] == "ssh" else {
    raise SshError(
      "Enter an SSH command such as ssh user@host or ssh -p 2222 host",
    )
  }
  let result : Array[String] = [
    "-T", "-oControlMaster=no", "-oControlPath=none", "-oRemoteCommand=none", "-oRequestTTY=no",
    "-oBatchMode=yes", "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=2",
  ]
  let mut i = 1
  while i < tokens.length() - 1 {
    let option = tokens[i]
    guard ["-p", "-i", "-J", "-l", "-F"].contains(option) &&
      i + 1 < tokens.length() - 1 else {
      raise SshError(
        "Supported SSH options: -p, -i, -J, -l, -F; put other connection settings in ~/.ssh/config",
      )
    }
    result.push(option)
    result.push(tokens[i + 1])
    i += 2
  }
  let destination = tokens[tokens.length() - 1]
  guard !destination.is_empty() && !destination.has_prefix("-") else {
    raise SshError("Missing SSH destination")
  }
  result.push(destination)
  result
}

///|
fn remote_command(server : String) -> String raise {
  guard !server.is_empty() && !server.contains("\n") else {
    raise SshError("Missing remote app-server executable")
  }
  "exec '" + server.replace(old="'", new="'\"'\"'") + "' app-server"
}
