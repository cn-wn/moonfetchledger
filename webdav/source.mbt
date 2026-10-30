///|
pub suberror SourceError {
  InvalidConfig(String)
  RequestFailed(String)
} derive(Debug)

///|
pub extend SourceError with Debug::{to_repr}

///|
/// A single trusted object bound to the existing WebDAV client's range API.
/// Credentials remain in that client, never in the ledger/checkpoint/report.
pub struct Source {
  spec : @ledger.ObjectSpec
  priv client : @upstream.WebdavClient
  priv path : String
}

///|
/// Construct an exact URL binding. Inputs must fit the upstream Int32 range
/// boundary. Authenticated HTTP is restricted to explicit 127.0.0.1 tests.
pub fn Source::new(
  spec : @ledger.ObjectSpec,
  config : @upstream.WebdavConfig,
  path : String,
  allow_loopback_auth~ : Bool = false,
) -> Source raise {
  make_source(
    spec,
    config,
    path,
    @wire.HttpConnTransport::new(),
    allow_loopback_auth,
  )
}

///|
fn make_source(
  spec : @ledger.ObjectSpec,
  config : @upstream.WebdavConfig,
  path : String,
  inner : &@transport.Transport,
  allow_loopback_auth : Bool,
) -> Source raise {
  if spec.length > 2147483647L {
    raise InvalidConfig(
      "WebDAV adapter supports at most 2147483647 bytes; upstream ranges are Int32",
    )
  }
  if path.is_empty() ||
    config.base_url.is_empty() ||
    config.base_url.contains("?") ||
    config.base_url.contains("#") {
    raise InvalidConfig(
      "WebDAV requires a nonempty path and a base URL without query or fragment",
    )
  }
  let base = if config.base_url.has_suffix("/") {
    config.base_url[:config.base_url.length() - 1].to_owned()
  } else {
    config.base_url
  }
  let normalized = if path.has_prefix("/") { path } else { "/" + path }
  let resource = base + @dav_types.percent_encode_path(normalized)
  if resource != spec.resource {
    raise InvalidConfig(
      "WebDAV base/path must exactly match the trusted ObjectSpec resource",
    )
  }
  for c in resource {
    if c.to_int() < 33 || c.to_int() > 126 || c == '\\' {
      raise InvalidConfig(
        "WebDAV URL requires ASCII without spaces, controls or backslashes",
      )
    }
  }
  let target = @wire.parse_target(resource) catch {
    _ =>
      raise InvalidConfig(
        "WebDAV requires a valid HTTP/HTTPS URL without userinfo",
      )
  }
  if target.scheme != "http" && target.scheme != "https" {
    raise InvalidConfig("WebDAV requires HTTP or HTTPS")
  }
  let authority = resource[resource.find("://").unwrap() + 3:]
    .split("/")
    .collect()[0]
  // Do not inherit an upstream Int32 port parse overflow or silently normalize
  // an empty/noncanonical port into a different wire destination.
  if target.host.is_empty() ||
    target.host.has_suffix(":") ||
    (
      authority != target.host &&
      authority != target.host + ":" + target.port.to_string()
    ) {
    raise InvalidConfig(
      "WebDAV URL requires a nonempty host and a canonical port in 1..65535",
    )
  }
  if target.host.contains("@") {
    raise InvalidConfig(
      "WebDAV URL must not contain userinfo; use the transient client configuration",
    )
  }
  if config.password is Some(_) && config.username is None {
    raise InvalidConfig("WebDAV password requires a username")
  }
  if config.username is Some(_) &&
    !target.use_tls &&
    (!allow_loopback_auth || target.host != "127.0.0.1") {
    raise InvalidConfig(
      "WebDAV credentials require HTTPS; explicit 127.0.0.1 HTTP is test-only",
    )
  }
  let timeout = config.timeout_ms.unwrap_or(30000)
  if timeout < 1 || timeout > 120000 {
    raise InvalidConfig("WebDAV request timeout must be 1..120000 ms")
  }
  let checked_transport : &@transport.Transport = GuardTransport::{
    inner,
    spec,
  }
  {
    spec,
    path,
    client: @upstream.create_webdav_client_with_transport(
      config, checked_transport,
    ),
  }
}

///|
/// Reuse saved coverage and repair only gaps/corrupt blocks using WebDAV get_file.
/// The ledger, filesystem lock, checkpoints, audit and final digest are shared
/// with the native host. HTTP status/encoding/range failures never write content.
pub async fn Source::receive(
  self : Source,
  output : String,
  chunk_size~ : Int32 = 65536,
  parallel~ : Int32 = 4,
  stop_after_blocks? : Int32,
  on_progress? : async (@host.DownloadProgress) -> Unit,
  pause_signal? : @ledger.PauseSignal,
  checkpoint_blocks~ : Int32 = 1,
  control? : @host.UpdateControl,
) -> @host.DownloadReport {
  @host.receive_from(
    self.spec,
    output,
    chunk_size~,
    parallel~,
    stop_after_blocks?,
    on_progress?,
    pause_signal?,
    checkpoint_blocks~,
    control?,
    fetch_range=range => self.fetch(range),
  )
}

///|
async fn Source::fetch(
  self : Source,
  range : @ledger.ByteRange,
) -> @host.ReceivedBlock {
  let result = self.client.get_file(
    path=self.path,
    range=@upstream.ByteRange::from(
      start=range.start.to_int(),
      end=(range.end - 1L).to_int(),
    ),
    conditions=@upstream.Conditions::new(if_match=self.spec.etag),
  ) catch {
    _ =>
      raise RequestFailed(
        "WebDAV range request failed: check endpoint/credentials; require 206, matching ETag/range/length and identity encoding; retain files for retry",
      )
  }
  let actual = match result.content_range {
    Some(value) => value
    None => raise RequestFailed("WebDAV response lacks Content-Range")
  }
  {
    bytes: result.content,
    status: result.status,
    etag: result.etag.unwrap_or(""),
    range: { start: actual.first.to_int64(), end: actual.last.to_int64() + 1L, },
    total: actual.total.unwrap_or(-1).to_int64(),
    content_encoding: "identity",
  }
}
