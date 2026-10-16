///|
/// Optional reference HTTP adapter. The receive/recovery workflow is shared with
/// receive_from so ecosystem adapters use exactly the same on-disk contract.
pub async fn download(
  spec : @ledger.ObjectSpec,
  output : String,
  chunk_size~ : Int32 = 65536,
  parallel~ : Int32 = 4,
  stop_after_blocks? : Int32,
  max_attempts~ : Int32 = 1,
  retry_delay_ms~ : Int32 = 200,
  request_timeout_ms~ : Int32 = 30000,
  on_progress? : async (DownloadProgress) -> Unit,
  pause_signal? : @ledger.PauseSignal,
  auth? : BearerAuth,
) -> DownloadReport {
  if auth is Some(credential) {
    credential.check_resource(spec.resource)
  }
  if max_attempts < 1 ||
    max_attempts > 8 ||
    retry_delay_ms < 0 ||
    retry_delay_ms > 30000 ||
    request_timeout_ms < 1 ||
    request_timeout_ms > 120000 {
    raise InvalidInput(
      "attempts must be 1..8; retry delay 0..30000 ms; request timeout 1..120000 ms",
    )
  }
  if !spec.resource.has_prefix("http://") &&
    !spec.resource.has_prefix("https://") {
    raise InvalidInput("HTTP or HTTPS resource required")
  }
  receive_from(
    spec,
    output,
    chunk_size~,
    parallel~,
    stop_after_blocks?,
    on_progress?,
    pause_signal?,
    fetch_range=range => {
      let bytes = fetch(
        spec, range, max_attempts, retry_delay_ms, request_timeout_ms, auth,
      )
      // fetch checks these exact response fields before returning the body.
      {
        bytes,
        status: 206,
        etag: spec.etag,
        range,
        total: spec.length,
        content_encoding: "identity",
      }
    },
  )
}
