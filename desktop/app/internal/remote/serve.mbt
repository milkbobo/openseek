///|
/// Relay registration/dialling stays native; request scheduling and delivery
/// run through the same shared transport as a headless host connection.
priv struct WsClientActor {
  state : @api.DesktopState
}

///|
fn WsClientActor::WsClientActor(state : @api.DesktopState) -> WsClientActor {
  { state, }
}

///|
async fn WsClientActor::run(self : WsClientActor, url : String) -> Unit {
  let conn = @websocket.Conn::connect(url)
  defer conn.close()
  self.serve(conn) catch {
    _ => ()
  }
}

///|
async fn WsClientActor::serve(
  self : WsClientActor,
  conn : @websocket.Conn,
) -> Unit {
  let connection = @host.HostConnection()
  let handlers : Array[@transport.RequestHandler] = @api.endpoints(
    self.state,
    connection,
  ).map(endpoint => {
    name: endpoint.name(),
    invoke: params => endpoint.invoke(params),
  })
  let client = @transport.Client(
    handlers,
    (emit, on_lag) => {
      let sub = self.state.subscribe_with(offer=event => emit(event), on_lag=sub => {
        sub.close()
        on_lag()
      })
      () => sub.close()
    },
    (emit, progress) => connection.run(emit, progress),
  )
  client.serve(conn, make_endpoints=notify => {
    @api.endpoints(self.state, connection, on_share_progress=payload => {
      notify(SessionShareProgress(payload))
    }).map(endpoint => {
      name: endpoint.name(),
      invoke: params => endpoint.invoke(params),
    })
  })
}
