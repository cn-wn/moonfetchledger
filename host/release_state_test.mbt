///|
fn release_seed() -> Bytes {
  Bytes::makei(32, i => (31 - i).to_byte())
}

///|
suberror ExpectedReleaseActionFailure {
  Expected
}

///|
fn release_trust() -> @release.ReleaseTrust raise {
  @release.ReleaseTrust::new(
    @ed25519.derive_public_key(release_seed()),
    "datasets",
    "stable",
  )
}

///|
fn release_bytes(
  version : Int64,
  pin~ : String = @ledger.digest(b"delta"),
) -> Bytes raise {
  @release.Release::new(
    "datasets", "stable", version, 100L, 200L, "https://example.test/delta", pin,
  ).sign(release_seed())
}

///|
async test "release state rejects rollback equivocation and backward clock across reopen while retrying same release" {
  let dir = @fs.tmpdir(prefix="mfl-release-state-")
  defer @fs.rmdir(dir, recursive=true)
  let state = dir + "/state"
  let trust = release_trust()
  @host.initialize_release_state(state, trust)
  let mut calls = 0
  let result = @host.with_release_state(state, trust, release_bytes(2L), 120L, action=r => {
    calls += 1
    r.release.version
  })
  assert_eq(result, 2L)
  assert_eq(
    @host.with_release_state(state, release_trust(), release_bytes(2L), 121L, action=_ => {
      calls += 1
      42
    }),
    42,
  )
  let saved = @fs.read_file(state).binary()
  for
    (bytes, now) in [
      (release_bytes(1L), 122L),
      (release_bytes(2L, pin=@ledger.digest(b"different")), 122L),
      (release_bytes(3L), 119L),
    ] {
    try
      @host.with_release_state(state, trust, bytes, now, action=_ => calls += 1)
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong rollback error")
    } noraise {
      _ => fail("accepted rollback/equivocation/clock reversal")
    }
    assert_eq(@fs.read_file(state).binary(), saved)
  }
  assert_eq(calls, 2)
  @host.with_release_state(state, trust, release_bytes(3L), 122L, action=_ => {
    calls += 1
  })
  assert_eq(calls, 3)
  try @host.initialize_release_state(state, trust) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong reinitialize error")
  } noraise {
    _ => fail("reset existing state")
  }
}

///|
async test "release action failure advances version durably and exclusive state lock covers action" {
  let dir = @fs.tmpdir(prefix="mfl-release-action-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/state"
  let trust = release_trust()
  @host.initialize_release_state(path, trust)
  try
    @host.with_release_state(path, trust, release_bytes(2L), 120L, action=async fn(
      _ : @release.ApprovedRelease,
    ) -> Unit {
      try
        @host.with_release_state(path, trust, release_bytes(3L), 121L, action=_ => {
          ()
        })
      catch {
        @host.OutputLocked => ()
        _ => fail("wrong concurrent access error")
      } noraise {
        _ => fail("concurrent update entered state")
      }
      raise Expected
    })
  catch {
    Expected => ()
    _ => fail("unexpected action failure")
  } noraise {
    _ => fail("lost action failure")
  }
  try
    @host.with_release_state(path, trust, release_bytes(1L), 121L, action=_ => {
      ()
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong retained floor error")
  } noraise {
    _ => fail("action error reset floor")
  }
  @host.with_release_state(path, trust, release_bytes(2L), 121L, action=_ => ())
}

///|
async test "malformed missing and policy-mismatched state never resets or changes local data" {
  let dir = @fs.tmpdir(prefix="mfl-release-malformed-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/state"
  let trust = release_trust()
  @host.initialize_release_state(path, trust)
  let initial = @fs.read_file(path).binary()
  for bytes in [b"\xff", b"[]", initial + b" ", Bytes::make(4097, b'x')] {
    @fs.write_file(path, bytes)
    try
      @host.with_release_state(path, trust, release_bytes(2L), 120L, action=_ => {
        ()
      })
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong state corruption error")
    } noraise {
      _ => fail("accepted corrupt store")
    }
    assert_eq(@fs.read_file(path).binary(), bytes)
  }
  @fs.write_file(path, initial)
  let different = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(release_seed()),
    "datasets",
    "stable",
    minimum_version=2L,
  )
  try
    @host.with_release_state(path, different, release_bytes(2L), 120L, action=_ => {
      ()
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong policy mismatch")
  } noraise {
    _ => fail("changed stored policy implicitly")
  }
  @fs.remove(path)
  try
    @host.with_release_state(path, trust, release_bytes(2L), 120L, action=_ => {
      ()
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong missing state error")
  } noraise {
    _ => fail("recreated missing state")
  }
  assert_true(!@fs.exists(path))
  @fs.write_file(path, initial)
  @host.with_release_state(path, trust, release_bytes(2L), 120L, action=_ => ())
}

///|
async test "interrupted release saves recover monotonically and refuse stale or malformed candidates" {
  let dir = @fs.tmpdir(prefix="mfl-release-pending-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/state"
  let trust = release_trust()
  @host.initialize_release_state(path, trust)
  let initial = @fs.read_file(path).binary()
  @host.with_release_state(path, trust, release_bytes(2L), 120L, action=_ => ())
  let newer = @fs.read_file(path).binary()
  @fs.write_file(path, initial)
  @fs.write_file(path + ".next", newer)
  try
    @host.with_release_state(path, trust, release_bytes(1L), 121L, action=_ => {
      ()
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong pending save error")
  } noraise {
    _ => fail("ignored pending version")
  }
  @host.recover_release_state(path, trust)
  assert_eq(@fs.read_file(path).binary(), newer)
  assert_true(!@fs.exists(path + ".next"))
  for stale in [initial, b"[]", newer + b" ", b"\xff"] {
    @fs.write_file(path + ".next", stale)
    try @host.recover_release_state(path, trust) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong pending refusal")
    } noraise {
      _ => fail("accepted unsafe pending state")
    }
    assert_eq(@fs.read_file(path + ".next").binary(), stale)
    assert_eq(@fs.read_file(path).binary(), newer)
  }
  @fs.write_file(path + ".next", newer)
  @host.recover_release_state(path, trust)
  @host.with_release_state(path, trust, release_bytes(2L), 121L, action=_ => ())
}
