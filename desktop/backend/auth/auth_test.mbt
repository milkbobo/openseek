///|
test "url derivations" {
  inspect(
    @auth.tunnel_url("https://openseek-api.moonbitlang.cn"),
    content="wss://openseek-api.moonbitlang.cn/v1/tunnel",
  )
  inspect(
    @auth.tunnel_url("http://127.0.0.1:3000/"),
    content="ws://127.0.0.1:3000/v1/tunnel",
  )
  inspect(
    @auth.device_url("https://relay.example", "d_abc"),
    content="https://relay.example/device/d_abc/chat",
  )
  inspect(
    @auth.device_url("https://relay.example/", "d a/b"),
    content="https://relay.example/device/d%20a%2Fb/chat",
  )
  inspect(
    @auth.origin_from_relay_url("wss://relay.example/v1/tunnel"),
    content="https://relay.example",
  )
  inspect(
    @auth.origin_from_relay_url("ws://127.0.0.1:8080/v1/tunnel"),
    content="http://127.0.0.1:8080",
  )
}
