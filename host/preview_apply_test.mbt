///|
suberror PreviewObserverFailed

///|
async test "preview approval reuses one scan for a multi seed update and preserves saved output" {
  let dir = @fs.tmpdir(prefix="mfl-preview-apply-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEFghi!"
  let reference = seed_reference(dir, data, 3)
  let a = dir + "/a"
  let b = dir + "/b"
  @fs.write_file(a, b"!abc")
  @fs.write_file(b, b"DEFghi")
  let expected = @host.preview_seeds(reference, [a, b])
  let output = dir + "/out"
  let mut decisions = 0
  let mut approved = false
  let control = @host.UpdateControl::new(on_progress=p => {
    if approved {
      assert_true(p.phase != @host.Scanning)
    }
  })
  let result = @host.update_from_seeds(
    reference,
    [a, b],
    output,
    export_to=dir + "/ready",
    control~,
    max_scan_bytes=10L,
    max_hash_bytes=expected.hashed_bytes,
    checkpoint_blocks=2,
    on_preview=plan => {
      decisions += 1
      assert_eq(plan.to_json(), expected.to_json())
      assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
      let records = plan.matches()
      records.clear() // Accessors cannot mutate the plan that will be applied.
      approved = true
      true
    },
  )
  assert_eq(decisions, 1)
  assert_true(result.receive.complete && result.exported)
  assert_eq(result.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), data)
  assert_eq(@fs.read_file(a).binary(), b"!abc")
  assert_eq(@fs.read_file(b).binary(), b"DEFghi")
}

///|
async test "declined or failed preview creates no staging and a fresh retry succeeds" {
  let dir = @fs.tmpdir(prefix="mfl-preview-decline-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdef"
  let reference = seed_reference(dir, data, 3)
  let seed = dir + "/seed"
  let output = dir + "/out"
  @fs.write_file(seed, data)
  let before = @fs.readdir(dir)
  try
    @host.update_from_seed(reference, output, seed~, on_preview=_ => false)
  catch {
    @host.PreviewDeclined => ()
    _ => fail("wrong declined-preview error")
  } noraise {
    _ => fail("declined preview was applied")
  }
  assert_eq(@fs.readdir(dir), before)
  try
    @host.update_from_seed(reference, output, seed~, on_preview=_ => {
      raise PreviewObserverFailed
    })
  catch {
    PreviewObserverFailed => ()
    _ => fail("preview observer error was masked")
  } noraise {
    _ => fail("preview observer error was swallowed")
  }
  assert_eq(@fs.readdir(dir), before)
  assert_true(
    @host.update_from_seed(reference, output, seed~, on_preview=_ => true).receive.complete,
  )
  let saved = @fs.read_file(output + ".mfl").binary()
  try
    @host.update_from_seed(reference, output, resuming=true, on_preview=_ => {
      true
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong resume/preview control refusal")
  } noraise {
    _ => fail("resume silently ignored preview callback")
  }
  assert_eq(@fs.read_file(output + ".mfl").binary(), saved)
}

///|
async test "preview cancellation and changed source length refuse before target creation" {
  let dir = @fs.tmpdir(prefix="mfl-preview-mutation-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcdef", 3)
  let seed = dir + "/seed"
  let output = dir + "/out"
  @fs.write_file(seed, b"abcdef")
  let control = @host.UpdateControl::new()
  try
    @host.update_from_seed(reference, output, seed~, control~, on_preview=_ => {
      control.request_pause()
      true
    })
  catch {
    @host.UpdatePaused(@host.Scanning, false) => ()
    _ => fail("preview decision ignored pending cancellation")
  } noraise {
    _ => fail("created cancelled target")
  }
  assert_true(!@fs.exists(output + ".mfl.lock"))
  try
    @host.update_from_seed(reference, output, seed~, on_preview=_ => {
      @fs.write_file(seed, b"abcdef!")
      true
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong changed-length refusal")
  } noraise {
    _ => fail("applied changed-length preview")
  }
  assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
}

///|
async test "same size source mutation after preview is strongly rechecked and partial state recovers" {
  let dir = @fs.tmpdir(prefix="mfl-preview-recheck-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEF"
  let reference = seed_reference(dir, data, 3)
  let seed = dir + "/seed"
  let output = dir + "/out"
  @fs.write_file(seed, data)
  try
    @host.update_from_seed(reference, output, seed~, on_preview=_ => {
      @fs.write_file(seed, b"abcXYZ")
      true
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("preview authorized changed source content")
  }
  let saved = @ledger.restore(
    @fs.read_file(output + ".mfl").text(),
    reference.spec,
  )
  assert_eq(saved.recovery_ranges(), [{ start: 0L, end: 3L, }])
  assert_eq(@fs.read_file(output).binary(), b"abc")
  let result = @host.receive_from(reference.spec, output, chunk_size=3, fetch_range=r => {
    assert_eq(r.start, 3L)
    {
      bytes: data[3:].to_owned(),
      status: 206,
      etag: reference.spec.etag,
      range: r,
      total: 6L,
      content_encoding: "identity",
    }
  })
  assert_true(result.complete)
  assert_eq(result.downloaded_blocks, 1)
  assert_eq(@fs.read_file(output).binary(), data)
  assert_eq(@fs.read_file(seed).binary(), b"abcXYZ")
}

///|
async test "preview cannot replace a destination that appears during the decision" {
  let dir = @fs.tmpdir(prefix="mfl-preview-destination-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abc", 3)
  let seed = dir + "/seed"
  let output = dir + "/out"
  @fs.write_file(seed, b"abc")
  try
    @host.reuse_from_seed(reference, seed, output, on_preview=_ => {
      @fs.write_file(output, b"foreign", create_mode=CreateNew)
      true
    })
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong occupied-preview destination error")
  } noraise {
    _ => fail("replaced destination after preview")
  }
  assert_eq(@fs.read_file(output).binary(), b"foreign")
  assert_true(!@fs.exists(output + ".mfl.lock"))
}

///|
async test "signed preview decline retains accepted version floor and can retry same release" {
  let dir = @fs.tmpdir(prefix="mfl-signed-preview-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEF"
  let reference = seed_reference(dir, data, 3)
  let trust = release_trust()
  let signed = release_bytes(2L, pin=@ledger.digest(reference.to_bytes()))
  let state = dir + "/state"
  let seed = dir + "/seed"
  let output = dir + "/out"
  @fs.write_file(seed, data)
  @host.initialize_release_state(state, trust)
  let initial = @fs.read_file(state).binary()
  try
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      seed~,
      metadata_file=dir + "/delta",
      on_preview=_ => false,
    )
  catch {
    @host.PreviewDeclined => ()
    _ => fail("signed preview decline was masked")
  } noraise {
    _ => fail("declined signed update proceeded")
  }
  let accepted = @fs.read_file(state).binary()
  assert_true(accepted != initial && !@fs.exists(output + ".mfl.lock"))
  try
    @host.with_release_state(
      state,
      trust,
      release_bytes(1L, pin=@ledger.digest(reference.to_bytes())),
      120L,
      action=_ => (),
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong rollback refusal after preview")
  } noraise {
    _ => fail("preview reset release floor")
  }
  let result = @host.update_signed_release(
    signed,
    trust,
    state,
    output,
    now=120L,
    seed~,
    metadata_file=dir + "/delta",
    on_preview=plan => plan.download_bytes() == 0L,
  )
  assert_true(result.update.receive.complete)
  assert_eq(@fs.read_file(state).binary(), accepted)
  assert_eq(@fs.read_file(output).binary(), data)
}
