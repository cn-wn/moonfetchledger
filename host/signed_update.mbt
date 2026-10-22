///|
/// Read a bounded, untrusted local announcement. Verification is separate.
pub async fn load_release(path : String) -> Bytes {
  read_release_file(path, 16384)
}

///|
/// Load an independently provisioned raw 32-byte publisher public key.
pub async fn load_release_trust(
  path : String,
  product : String,
  channel : String,
  minimum_version~ : Int64 = 1L,
) -> @release.ReleaseTrust {
  @release.ReleaseTrust::new(
    read_release_file(path, 32),
    product,
    channel,
    minimum_version~,
  )
}

///|
/// Offline signing from a raw private seed file, with no-replace publication.
/// No key bytes are returned or logged. Caller protects key permissions/storage.
pub async fn write_signed_release(
  descriptor : @release.Release,
  private_seed_file : String,
  destination : String,
) -> Unit {
  if destination.is_empty() ||
    @fs.exists(destination) ||
    @fs.exists(destination + ".next") ||
    canonical_entry(private_seed_file) == canonical_entry(destination) ||
    canonical_entry(private_seed_file) == canonical_entry(destination + ".next") {
    raise InvalidInput(
      "signed release requires new destination/temporary separate from private seed",
    )
  }
  let seed = read_release_file(private_seed_file, 32)
  let bytes = descriptor.sign(seed)
  publish_new(destination, f => f.write(bytes))
}

///|
/// Fetch UNTRUSTED announcement bytes, <=16384 bytes, without redirects or
/// decoding. update_signed_release verifies before any state or artifact writes.
pub async fn fetch_release(
  url : String,
  request_timeout_ms~ : Int32 = 30000,
) -> Bytes {
  validate_delta_url(url)
  if request_timeout_ms < 1 || request_timeout_ms > 120000 {
    raise InvalidInput("release timeout must be 1..120000 ms")
  }
  @async.with_timeout(request_timeout_ms, () => {
    let (response, client) = @http.get_stream(url, headers={
      "Accept-Encoding": "identity",
    })
    defer client.close()
    if response.code != 200 ||
      response.headers.get("Content-Encoding").unwrap_or("identity") !=
      "identity" ||
      response.headers.get("Content-Range") is Some(_) {
      raise InvalidResponse(
        "release requires an unencoded 200 without Content-Range; redirects unsupported",
      )
    }
    let declared = match response.headers.get("Content-Length") {
      Some(text) => {
        let n = number(text[:])
        if n > 16384L {
          raise InvalidResponse("release exceeds 16384 bytes")
        }
        Some(n.to_int())
      }
      None => None
    }
    let buffer = Buffer()
    let mut size = 0
    while client.read_some(max_len=(16385 - size).min(4096)) is Some(bytes) {
      size += bytes.length()
      if size > 16384 {
        raise InvalidResponse("release exceeds 16384 bytes")
      }
      buffer.write_bytes(bytes)
    }
    if declared is Some(n) && n != size {
      raise InvalidResponse(
        "release Content-Length differs from received bytes",
      )
    }
    buffer.to_bytes()
  }) catch {
    InvalidResponse(_) as e => raise e
    @async.TimeoutError =>
      raise InvalidResponse("release request timed out; retain files and retry")
    _ =>
      raise InvalidResponse(
        "release HTTP request failed; check origin/network and retry",
      )
  }
}

///|
pub struct SignedUpdateReport {
  version : Int64
  payload_sha256 : String
  update : DeltaUpdateReport
}

///|
/// Authenticate, persist monotonic acceptance, fetch hash-bound metadata, then
/// rebuild/download/export. A valid release remains accepted after network or
/// artifact failure; correct the cause and retry that same release explicitly.
/// now is a trusted Unix clock at operation start, never supplied by the server.
pub async fn update_signed_release(
  signed_release : Bytes,
  trust : @release.ReleaseTrust,
  state : String,
  output : String,
  now~ : Int64,
  metadata_file? : String,
  seed? : String,
  resuming~ : Bool = false,
  export_to? : String,
  parallel~ : Int32 = 4,
  stop_after_blocks? : Int32,
  max_attempts~ : Int32 = 1,
  request_timeout_ms~ : Int32 = 30000,
  auth? : BearerAuth,
) -> SignedUpdateReport {
  let checked = trust.verify(signed_release, now)
  validate_delta_url(checked.release.metadata_url)
  if state.is_empty() ||
    output.is_empty() ||
    parallel < 1 ||
    parallel > 16 ||
    max_attempts < 1 ||
    max_attempts > 8 ||
    request_timeout_ms < 1 ||
    request_timeout_ms > 120000 ||
    (stop_after_blocks is Some(n) && n < 0) ||
    resuming == (seed is Some(_)) {
    raise InvalidInput(
      "signed update requires state/output, exactly seed or resume, and valid parallel/attempt/timeout/block limits",
    )
  }
  // State paths must never be used as artifact/session/input/delivery paths.
  let state_paths = [
    canonical_entry(state),
    canonical_entry(state + ".lock"),
    canonical_entry(state + ".next"),
  ]
  let paths = [
    output,
    output + ".mfl",
    output + ".mfl.lock",
    output + ".mfl.next",
    output + ".mfl.recovering",
  ]
  if seed is Some(p) {
    paths.push(p)
  }
  if metadata_file is Some(p) {
    paths.push(p)
  }
  if export_to is Some(p) {
    paths.push(p)
    paths.push(p + ".next")
  }
  for path in paths {
    if state_paths.contains(canonical_entry(path)) {
      raise InvalidInput("signed update path aliases protected release state")
    }
  }
  if resuming {
    for suffix in ["", ".mfl", ".mfl.lock"] {
      if !@fs.exists(output + suffix) {
        raise InvalidInput(
          "signed resume requires existing staging/checkpoint/lock",
        )
      }
    }
  } else {
    for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
      if @fs.exists(output + suffix) {
        raise InvalidInput(
          "new signed update requires new staging and sidecars; use explicit resume",
        )
      }
    }
  }
  if export_to is Some(path) {
    let destinations = [canonical_entry(path), canonical_entry(path + ".next")]
    let mut aliases = false
    for
      p in [
        output,
        output + ".mfl",
        output + ".mfl.lock",
        output + ".mfl.next",
        output + ".mfl.recovering",
      ] {
      if destinations.contains(canonical_entry(p)) {
        aliases = true
      }
    }
    if @fs.exists(path) || @fs.exists(path + ".next") || aliases {
      raise InvalidInput(
        "signed delivery requires new paths separate from staging",
      )
    }
  }
  with_release_state(state, trust, signed_release, now, action=approved => {
    let reference = match metadata_file {
      Some(path) => load_delta_reference(path, approved.release.metadata_sha256)
      None =>
        fetch_delta_reference(
          approved.release.metadata_url,
          approved.release.metadata_sha256,
          request_timeout_ms~,
        )
    }
    let update = update_from_seed(
      reference,
      output,
      seed?,
      resuming~,
      export_to?,
      parallel~,
      stop_after_blocks?,
      max_attempts~,
      request_timeout_ms~,
      auth?,
    )
    {
      version: approved.release.version,
      payload_sha256: approved.payload_sha256,
      update,
    }
  })
}
