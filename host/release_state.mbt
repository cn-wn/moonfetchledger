///|
priv struct ReleaseState {
  version : Int64
  payload : String
  observed_at : Int64
}

///|
fn ReleaseState::bytes(
  self : ReleaseState,
  trust : @release.ReleaseTrust,
) -> Bytes {
  @utf8.encode(
    Json::array([
      Json::string("MFLRELEASE-STATE1"),
      Json::string(trust.product),
      Json::string(trust.channel),
      Json::string(trust.key_sha256),
      Json::string(trust.minimum_version.to_string()),
      Json::string(self.version.to_string()),
      Json::string(self.payload),
      Json::string(self.observed_at.to_string()),
    ]).stringify(),
  )
}

///|
// Same-handle bounded reads; no unbounded read_file after a path stat.
async fn read_release_file(path : String, limit : Int32) -> Bytes {
  if path.is_empty() || @fs.kind(path) != Regular {
    raise InvalidInput("release input must be a regular file; retain it")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  if file.kind() != Regular || size > limit.to_int64() {
    raise InvalidInput("release input exceeds its byte bound or is not regular")
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  if file.read_at(FixedArray::make(1, b'\x00'), position=size) != 0 ||
    file.size() != size {
    raise InvalidInput("release input changed length while reading")
  }
  bytes
}

///|
async fn read_release_state(
  path : String,
  trust : @release.ReleaseTrust,
) -> ReleaseState {
  let bytes = read_release_file(path, 4096)
  let text = @utf8.decode(bytes) catch {
    _ => raise InvalidInput("release state requires strict UTF-8; retain it")
  }
  let value = @json.parse(text) catch {
    _ =>
      raise InvalidInput(
        "malformed release state; never reset it automatically",
      )
  }
  let state = match value {
    [
      String("MFLRELEASE-STATE1"),
      String(product),
      String(channel),
      String(key),
      String(floor),
      String(version),
      String(payload),
      String(observed),
    ] => {
      if product != trust.product ||
        channel != trust.channel ||
        key != trust.key_sha256 ||
        floor != trust.minimum_version.to_string() {
        raise InvalidInput(
          "release state differs from pinned policy; preserve it",
        )
      }
      let version = number(version[:])
      let observed_at = number(observed[:])
      if (version == 0L && (payload != "" || observed_at != 0L)) ||
        (
          version > 0L &&
          (
            version < trust.minimum_version ||
            payload.length() != 64 ||
            !payload
            .iter()
            .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
          )
        ) {
        raise InvalidInput(
          "invalid release state version/payload/time; preserve it",
        )
      }
      ReleaseState::{ version, payload, observed_at, }
    }
    _ => raise InvalidInput("unsupported release state schema or extra fields")
  }
  if state.bytes(trust) != bytes {
    raise InvalidInput("release state must be canonical; preserve it")
  }
  state
}

///|
async fn release_state_lock(path : String) -> @fs.File {
  if path.is_empty() ||
    !@fs.exists(path) ||
    !@fs.exists(path + ".lock") ||
    @fs.kind(path + ".lock") != Regular {
    raise InvalidInput(
      "release state and its existing regular .lock are required; initialize explicitly once",
    )
  }
  let file = @fs.open(path + ".lock", mode=ReadWrite)
  if !file.try_lock(Exclusive) {
    file.close()
    raise OutputLocked
  }
  file
}

///|
/// Explicit first-use operation in a protected directory. Refuse existing state,
/// lock or pending data. A partially initialized store is retained for inspection.
pub async fn initialize_release_state(
  path : String,
  trust : @release.ReleaseTrust,
) -> Unit {
  if path.is_empty() {
    raise InvalidInput("release state path is required")
  }
  for suffix in ["", ".lock", ".next"] {
    if @fs.exists(path + suffix) {
      raise InvalidInput(
        "release state initialization requires new state/lock/pending paths",
      )
    }
  }
  let lock = @fs.open(path + ".lock", mode=ReadWrite, create_mode=CreateNew)
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  if @fs.exists(path) || @fs.exists(path + ".next") {
    raise InvalidInput(
      "release state appeared during initialization; retain it",
    )
  }
  let initial : ReleaseState = { version: 0L, payload: "", observed_at: 0L, }
  publish_new(path, f => f.write(initial.bytes(trust)))
}

///|
fn check_release_advance(
  current : ReleaseState,
  next : ReleaseState,
) -> Unit raise HostError {
  if next.version < current.version ||
    next.observed_at < current.observed_at ||
    (next.version == current.version && next.payload != current.payload) {
    raise InvalidInput(
      "release rollback, backward clock or same-version equivocation refused; retain state",
    )
  }
}

///|
/// Verify before state mutation, save highest accepted version BEFORE action,
/// and hold the cooperative lock until action finishes. Action failure retains
/// the new floor; the identical release may retry, older releases may not.
/// Never let action modify the state, .lock or .next paths.
pub async fn[T] with_release_state(
  path : String,
  trust : @release.ReleaseTrust,
  signed_release : Bytes,
  now : Int64,
  action~ : async (@release.ApprovedRelease) -> T,
) -> T {
  let approved = trust.verify(signed_release, now)
  let lock = release_state_lock(path)
  defer lock.close()
  if @fs.exists(path + ".next") {
    raise InvalidInput(
      "pending release state exists; call recover_release_state explicitly",
    )
  }
  let current = read_release_state(path, trust)
  let next : ReleaseState = {
    version: approved.release.version,
    payload: approved.payload_sha256,
    observed_at: now,
  }
  check_release_advance(current, next)
  let bytes = next.bytes(trust)
  if bytes != current.bytes(trust) {
    let file = @fs.open(path + ".next", mode=ReadWrite, create_mode=CreateNew)
    defer file.close()
    // Leave owned pending bytes after I/O failure, so reopening cannot forget
    // a potentially accepted higher version. Explicit recovery validates both.
    file.write(bytes)
    file.sync()
    if file.read_exactly_at(bytes.length(), position=0L) != bytes ||
      file.size() != bytes.length().to_int64() {
      raise InvalidInput(
        "release state readback differs; preserve pending state",
      )
    }
    file.close()
    @fs.rename(path + ".next", path, replace=true)
  }
  action(approved)
}

///|
/// Reconcile an interrupted save under the existing lock. Both records must be
/// bounded, canonical and bound to the same policy. Pending state may only move
/// version/time forward; same-version payload replacement is refused.
pub async fn recover_release_state(
  path : String,
  trust : @release.ReleaseTrust,
) -> Unit {
  let lock = release_state_lock(path)
  defer lock.close()
  let current = read_release_state(path, trust)
  let candidate = read_release_state(path + ".next", trust)
  check_release_advance(current, candidate)
  @fs.rename(path + ".next", path, replace=true)
}
