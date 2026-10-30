///|
suberror UpdateObserverFailed

///|
async test "signed control pauses before authorization or metadata and retries without resetting version protection" {
  let dir = @fs.tmpdir(prefix="mfl-signed-control-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEF"
  let reference = seed_reference(dir, data, 3)
  let trust = release_trust()
  let signed = release_bytes(2L, pin=@ledger.digest(reference.to_bytes()))
  let seed = dir + "/seed"
  @fs.write_file(seed, data)
  for i, phase in [@host.Authorizing, @host.LoadingMetadata] {
    let state = dir + "/state-" + i.to_string()
    let output = state + ".staging"
    @host.initialize_release_state(state, trust)
    let before = @fs.read_file(state).binary()
    let signal = @ledger.PauseSignal::new()
    let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
      if p.phase == phase {
        signal.request_pause()
      }
    })
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        output,
        now=120L,
        seed~,
        metadata_file=dir + "/delta",
        control~,
      )
    catch {
      @host.UpdatePaused(actual, false) => assert_eq(actual, phase)
      _ => fail("lost signed pause location")
    } noraise {
      _ => fail("ignored signed pause")
    }
    assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
    if phase == @host.Authorizing {
      assert_eq(@fs.read_file(state).binary(), before)
    } else {
      let accepted = @fs.read_file(state).binary()
      assert_true(accepted != before)
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
        _ => fail("wrong rollback refusal after metadata pause")
      } noraise {
        _ => fail("metadata pause lost accepted version floor")
      }
      assert_eq(@fs.read_file(state).binary(), accepted)
    }
    let events : Array[@host.UpdateProgress] = []
    let resumed = @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      seed~,
      metadata_file=dir + "/delta",
      checkpoint_blocks=2,
      control=@host.UpdateControl::new(on_progress=p => events.push(p)),
    )
    assert_true(resumed.update.receive.complete)
    assert_eq(events[0].phase, @host.Authorizing)
    assert_eq(events.last().unwrap().phase, @host.Finished)
    assert_eq(@fs.read_file(output).binary(), data)
    // Pause before staging must never reset an already accepted version floor.
    try
      @host.with_release_state(
        state,
        trust,
        release_bytes(1L, pin=@ledger.digest(reference.to_bytes())),
        120L,
        action=_ => (),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("lost rollback protection")
    }
  }
}

///|
async test "update cancellation at scanning reuse verification and both export stages preserves inputs and resumes exactly" {
  let dir = @fs.tmpdir(prefix="mfl-update-control-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEFghi!"
  let reference = seed_reference(dir, data, 3)
  let source = dir + "/seed"
  @fs.write_file(source, data)
  let phases = [
    @host.Scanning,
    @host.Reusing,
    @host.Recovering,
    @host.Downloading,
    @host.Verifying,
    @host.Exporting,
    @host.CheckingExport,
  ]
  for i, phase in phases {
    let output = dir + "/out-" + i.to_string()
    let ready = output + ".ready"
    let signal = @ledger.PauseSignal::new()
    let events : Array[@host.UpdateProgress] = []
    let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
      events.push(p)
      if p.phase == phase && !p.paused {
        // Exercise actual work inside reuse, recovery, verification and export.
        if phase == @host.Scanning ||
          phase == @host.Downloading ||
          p.processed_bytes > 0L {
          signal.request_pause()
        }
      }
    })
    try
      @host.update_from_seed(
        reference,
        output,
        seed=source,
        export_to=ready,
        checkpoint_blocks=2,
        control~,
      )
    catch {
      @host.UpdatePaused(actual, resumable) => {
        assert_eq(actual, phase)
        assert_eq(resumable, phase != @host.Scanning)
      }
      _ => fail("wrong cooperative update result")
    } noraise {
      _ => fail("ignored update pause")
    }
    assert_eq(events.last().unwrap().phase, phase)
    assert_true(events.last().unwrap().paused)
    assert_true(!events.any(p => p.phase == @host.Finished))
    assert_eq(@fs.read_file(source).binary(), data)
    assert_true(!@fs.exists(ready) && !@fs.exists(ready + ".next"))
    if phase == @host.Scanning {
      assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
      assert_true(
        @host.update_from_seed(reference, output, seed=source, export_to=ready).exported,
      )
    } else {
      let restored = @ledger.restore(
        @fs.read_file(output + ".mfl").text(),
        reference.spec,
      )
      // Two reused blocks were installed before the pause. Supply the remaining
      // blocks through the generic source, then use the ordinary update resume.
      if phase == @host.Reusing {
        assert_eq(restored.recovery_ranges().length(), 2)
        ignore(
          @host.receive_from(reference.spec, output, fetch_range=r => {
            bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
            status: 206,
            etag: reference.spec.etag,
            range: r,
            total: reference.spec.length,
            content_encoding: "identity",
          }),
        )
      }
      let finished : Array[@host.UpdateProgress] = []
      let resumed = @host.update_from_seed(
        reference,
        output,
        resuming=true,
        export_to=ready,
        control=@host.UpdateControl::new(on_progress=p => finished.push(p)),
      )
      assert_true(resumed.receive.complete && resumed.exported)
      assert_eq(resumed.receive.downloaded_blocks, 0)
      assert_eq(finished.last().unwrap().phase, @host.Finished)
    }
    assert_eq(@fs.read_file(ready).binary(), data)
  }
}

///|
async test "update control drains network batch and saves its short tail before typed pause" {
  let dir = @fs.tmpdir(prefix="mfl-control-drain-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdef"
  let spec = audit_spec(data)
  let output = dir + "/out"
  let signal = @ledger.PauseSignal::new()
  let mut reads = 0
  let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
    if p.phase == @host.Downloading && p.confirmed_bytes >= 2L {
      signal.request_pause()
    }
  })
  try
    @host.receive_from(
      spec,
      output,
      chunk_size=1,
      parallel=3,
      checkpoint_blocks=2,
      control~,
      fetch_range=r => {
        reads += 1
        {
          bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
          status: 206,
          etag: spec.etag,
          range: r,
          total: spec.length,
          content_encoding: "identity",
        }
      },
    )
  catch {
    @host.UpdatePaused(@host.Downloading, true) => ()
    _ => fail("incorrect batch-draining pause")
  } noraise {
    _ => fail("ignored download pause")
  }
  assert_eq(reads, 3)
  let restored = @ledger.restore(@fs.read_file(output + ".mfl").text(), spec)
  assert_eq(restored.recovery_ranges().length(), 3)
  assert_eq(@fs.read_file(output).binary(), b"abc")
  let complete = @host.receive_from(spec, output, fetch_range=r => {
    assert_true(r.start >= 3L)
    {
      bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
      status: 206,
      etag: spec.etag,
      range: r,
      total: spec.length,
      content_encoding: "identity",
    }
  })
  assert_true(complete.complete)
  assert_eq(complete.recovery.retained_bytes, 3L)
}

///|
async test "observer errors preserve checkpoints and default APIs and progress serialization is exact" {
  let dir = @fs.tmpdir(prefix="mfl-control-observer-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEFghi!"
  let reference = seed_reference(dir, data, 3)
  let seed = dir + "/seed"
  @fs.write_file(seed, data)
  let output = dir + "/out"
  let signal = @ledger.PauseSignal::new()
  let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
    if p.phase == @host.Reusing && p.confirmed_bytes > 0L {
      raise UpdateObserverFailed
    }
  })
  try @host.update_from_seed(reference, output, seed~, control~) catch {
    UpdateObserverFailed => ()
    _ => fail("observer error lost")
  } noraise {
    _ => fail("observer error swallowed")
  }
  assert_true(!control.is_pause_requested())
  let saved = @ledger.restore(
    @fs.read_file(output + ".mfl").text(),
    reference.spec,
  )
  assert_eq(saved.recovery_ranges().length(), 1)
  let before = @fs.read_file(output + ".mfl").binary()
  let cancelled = @host.UpdateControl::new()
  cancelled.request_pause()
  try
    @host.update_from_seed(reference, output, resuming=true, control=cancelled)
  catch {
    @host.UpdatePaused(@host.Recovering, true) => ()
    _ => fail("pre-requested pause was not honored")
  } noraise {
    _ => fail("started pre-cancelled update")
  }
  assert_eq(@fs.read_file(output + ".mfl").binary(), before)
  let snapshots : Array[@host.UpdateProgress] = []
  let fresh = dir + "/fresh"
  let done = @host.update_from_seed(
    reference,
    fresh,
    seed~,
    control=@host.UpdateControl::new(on_progress=p => snapshots.push(p)),
  )
  assert_true(done.receive.complete)
  assert_eq(
    snapshots[0].to_json().stringify(),
    "[\"MFLUPDATEPROGRESS1\",\"scanning\",\"running\",\"0\",\"10\",\"0\",false]",
  )
  assert_eq(
    snapshots.last().unwrap().to_json().stringify(),
    "[\"MFLUPDATEPROGRESS1\",\"finished\",\"running\",\"10\",\"10\",\"10\",true]",
  )
}

///|
async test "empty update completes and final pause cannot undo delivered output" {
  let dir = @fs.tmpdir(prefix="mfl-empty-update-control-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"", 3)
  let seed = dir + "/seed"
  @fs.write_file(seed, b"")
  let signal = @ledger.PauseSignal::new()
  let events : Array[@host.UpdateProgress] = []
  let result = @host.update_from_seed(
    reference,
    dir + "/out",
    seed~,
    export_to=dir + "/ready",
    control=@host.UpdateControl::new(pause_signal=signal, on_progress=p => {
      events.push(p)
      assert_eq(p.processed_bytes, 0L)
      assert_eq(p.total_bytes, 0L)
      assert_eq(p.confirmed_bytes, 0L)
      if p.phase == @host.Finished {
        signal.request_pause()
      }
    }),
  )
  assert_true(result.receive.complete && result.exported)
  assert_true(signal.is_requested())
  assert_true(!events.any(p => p.paused))
  assert_eq(events.last().unwrap().phase, @host.Finished)
  assert_eq(@fs.read_file(dir + "/ready").binary(), b"")
}

///|
async test "loader observer failures remain typed and export observer failure removes only owned temporary" {
  let dir = @fs.tmpdir(prefix="mfl-control-failure-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcdef", 3)
  let bad = @host.UpdateControl::new(on_progress=_ => raise UpdateObserverFailed)
  for remote in [false, true] {
    try {
      if remote {
        ignore(
          @host.fetch_delta_reference(
            "https://example.test/delta",
            @ledger.digest(reference.to_bytes()),
            control=bad,
          ),
        )
      } else {
        ignore(
          @host.load_delta_reference(
            dir + "/delta",
            @ledger.digest(reference.to_bytes()),
            control=bad,
          ),
        )
      }
    } catch {
      UpdateObserverFailed => ()
      _ => fail("metadata observer error was masked")
    } noraise {
      _ => fail("ignored metadata observer error")
    }
  }
  let seed = dir + "/seed"
  @fs.write_file(seed, b"abcdef")
  let output = dir + "/out"
  let ready = dir + "/ready"
  try
    @host.update_from_seed(
      reference,
      output,
      seed~,
      export_to=ready,
      control=@host.UpdateControl::new(on_progress=p => {
        if p.phase == @host.CheckingExport && p.processed_bytes > 0L {
          raise UpdateObserverFailed
        }
      }),
    )
  catch {
    UpdateObserverFailed => ()
    _ => fail("export observer error was masked")
  } noraise {
    _ => fail("ignored export observer error")
  }
  assert_true(!@fs.exists(ready) && !@fs.exists(ready + ".next"))
  assert_eq(@fs.read_file(output).binary(), b"abcdef")
  assert_true(
    @host.update_from_seed(reference, output, resuming=true, export_to=ready).exported,
  )
  assert_eq(@fs.read_file(ready).binary(), b"abcdef")
}

///|
async test "multi seed scan reports aggregate work and pauses inside second file without staging" {
  let dir = @fs.tmpdir(prefix="mfl-scan-control-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcdef", 3)
  let first = dir + "/first"
  let second = dir + "/second"
  let a = Bytes::make(100000, b'x')
  let b = Bytes::make(100000, b'y')
  @fs.write_file(first, a)
  @fs.write_file(second, b)
  let signal = @ledger.PauseSignal::new()
  let events : Array[@host.UpdateProgress] = []
  let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
    events.push(p)
    if p.processed_bytes > 100000L {
      signal.request_pause()
    }
  })
  let output = dir + "/out"
  try
    @host.update_from_seeds(reference, [first, second], output, control~)
  catch {
    @host.UpdatePaused(@host.Scanning, false) => ()
    _ => fail("scan pause lost")
  } noraise {
    _ => fail("scan ignored cancellation")
  }
  assert_eq(events.last().unwrap().processed_bytes, 165536L)
  assert_true(events.last().unwrap().paused)
  for p in events {
    assert_eq(p.phase, @host.Scanning)
    assert_eq(p.total_bytes, 200000L)
    assert_eq(p.confirmed_bytes, 0L)
  }
  assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
  assert_eq(@fs.read_file(first).binary(), a)
  assert_eq(@fs.read_file(second).binary(), b)
}
