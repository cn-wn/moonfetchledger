///|
async test "local repair budgets preserve every sparse mask and resume exactly remaining blocks" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-budgets-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefg"
  let spec = audit_spec(data)
  let backup = dir + "/backup"
  @fs.write_file(backup, data)
  for mask in 0..<8 {
    for budget in 0..<4 {
      let path = dir + "/target-\{mask}-\{budget}"
      let indices = [0, 1, 2]
        .iter()
        .filter(i => (mask & (1 << i)) != 0)
        .collect()
      let missing = [0, 1, 2].iter().filter(i => !indices.contains(i)).collect()
      let sizes = [3L, 3L, 1L]
      let mut retained = 0L
      for i in indices {
        retained += sizes[i]
      }
      let copies = budget.min(missing.length())
      let mut expected = retained
      for i in 0..<copies {
        expected += sizes[missing[i]]
      }
      @fs.write_file(path, data)
      @fs.write_file(path + ".mfl", audit_checkpoint(spec, data, indices))
      @fs.write_file(path + ".mfl.lock", b"")
      let events : Array[@host.LocalRepairProgress] = []
      let report = @host.repair_from_local(
        spec,
        path,
        backup,
        stop_after_blocks=budget,
        on_progress=event => {
          let saved = @ledger.restore(@fs.read_file(path + ".mfl").text(), spec)
          let mut confirmed = 0L
          for range in saved.recovery_ranges() {
            confirmed += range.length()
          }
          assert_eq(event.confirmed_bytes, confirmed)
          if event.phase is @host.BlockCopied(range) {
            assert_eq(
              range.start,
              (missing[event.repaired_blocks - 1] * 3).to_int64(),
            )
            assert_true(saved.recovery_ranges().contains(range))
          }
          events.push(event)
        },
      )
      assert_eq(report.repaired_blocks, copies)
      assert_eq(report.recovery.retained_bytes, retained)
      assert_eq(report.confirmed_bytes, expected)
      assert_eq(report.complete, expected == 7L)
      assert_eq(events.length(), copies + 2)
      assert_true(events[0].phase is @host.Recovered)
      assert_eq(events[events.length() - 1].repaired_blocks, copies)
      if report.complete {
        assert_true(events[events.length() - 1].phase is @host.Complete)
      } else {
        assert_true(events[events.length() - 1].phase is @host.Paused)
      }
      assert_eq(@host.audit(spec, path).confirmed_bytes, expected)
      let resumed = @host.repair_from_local(spec, path, backup)
      assert_true(resumed.complete)
      assert_eq(resumed.recovery.retained_bytes, expected)
      assert_eq(resumed.repaired_blocks, missing.length() - copies)
      assert_eq(@fs.read_file(path).binary(), data)
      assert_eq(@fs.read_file(backup).binary(), data)
    }
  }
}

///|
async test "local repair pause intent stops between saved copies and completion takes precedence" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-signal-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(backup, data)
  @fs.write_file(path, b"XXXXXXX")
  @fs.write_file(path + ".mfl", audit_checkpoint(spec, data, [0, 1, 2]))
  @fs.write_file(path + ".mfl.lock", b"")
  for pre_requested in [true, false] {
    let signal = @ledger.PauseSignal::new()
    if pre_requested {
      signal.request_pause()
    }
    let events : Array[@host.LocalRepairProgress] = []
    let report = @host.repair_from_local(
      spec,
      path,
      backup,
      pause_signal=signal,
      on_progress=event => {
        events.push(event)
        if event.phase is @host.Recovered {
          signal.request_pause()
        }
      },
    )
    assert_true(!report.complete)
    assert_eq(report.repaired_blocks, 0)
    assert_eq(@fs.read_file(path).binary(), b"XXXXXXX")
    assert_eq(
      events[1].to_json().stringify(),
      "[\"MFLREPAIR1\",\"paused\",\"7\",\"0\",\"0\",null]",
    )
  }
  let signal = @ledger.PauseSignal::new()
  let events : Array[@host.LocalRepairProgress] = []
  let paused = @host.repair_from_local(
    spec,
    path,
    backup,
    pause_signal=signal,
    on_progress=event => {
      events.push(event)
      if event.phase is @host.BlockCopied(_) {
        signal.request_pause()
      }
    },
  )
  assert_true(!paused.complete)
  assert_eq(paused.repaired_blocks, 1)
  assert_eq(paused.confirmed_bytes, 3L)
  assert_eq(@fs.read_file(path).binary(), b"abcXXXX")
  assert_eq(
    events[1].to_json().stringify(),
    "[\"MFLREPAIR1\",\"block\",\"7\",\"3\",\"1\",[\"0\",\"3\"]]",
  )
  let checkpoint = @fs.read_file(path + ".mfl").binary()
  assert_eq(
    @host.repair_from_local(spec, path, backup, pause_signal=signal).repaired_blocks,
    0,
  )
  assert_eq(@fs.read_file(path + ".mfl").binary(), checkpoint)
  let resumed = @host.repair_from_local(
    spec,
    path,
    backup,
    pause_signal=@ledger.PauseSignal::new(),
  )
  assert_true(resumed.complete)
  assert_eq(resumed.repaired_blocks, 2)
  assert_eq(resumed.recovery.retained_bytes, 3L)
  assert_true(
    @host.repair_from_local(
      spec,
      path,
      backup,
      pause_signal=signal,
      stop_after_blocks=0,
    ).complete,
  )
  let empty = dir + "/empty"
  @fs.write_file(empty, b"")
  @fs.write_file(backup, b"")
  let spec = audit_spec(b"")
  @host.adopt(spec, empty)
  events.clear()
  assert_true(
    @host.repair_from_local(
      spec,
      empty,
      backup,
      pause_signal=signal,
      stop_after_blocks=0,
      on_progress=event => events.push(event),
    ).complete,
  )
  assert_eq(events.length(), 2)
  assert_true(events[1].phase is @host.Complete)
}

///|
async test "local repair observer errors preserve durable copies and release the lock" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-observer-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefg"
  let spec = audit_spec(data)
  let backup = dir + "/backup"
  @fs.write_file(backup, data)
  for fail_after in [0, 1] {
    let path = dir + "/target-\{fail_after}"
    @fs.write_file(path, b"XXXXXXX")
    @fs.write_file(path + ".mfl", audit_checkpoint(spec, data, []))
    @fs.write_file(path + ".mfl.lock", b"")
    let events : Array[@host.LocalRepairProgress] = []
    try
      @host.repair_from_local(spec, path, backup, on_progress=event => {
        events.push(event)
        if event.repaired_blocks == fail_after {
          raise ObserverStopped
        }
      })
    catch {
      ObserverStopped => ()
      _ => fail("lost local observer error")
    } noraise {
      _ => fail("ignored local observer failure")
    }
    assert_eq(events.length(), fail_after + 1)
    assert_eq(
      @host.audit(spec, path).confirmed_bytes,
      (fail_after * 3).to_int64(),
    )
    let resumed = @host.repair_from_local(spec, path, backup)
    assert_true(resumed.complete)
    assert_eq(resumed.repaired_blocks, 3 - fail_after)
    assert_eq(resumed.recovery.retained_bytes, (fail_after * 3).to_int64())
    assert_eq(@fs.read_file(path).binary(), data)
  }
}

///|
async test "pause and zero budget never bypass backup verification or input validation" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-validation-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  try @host.repair_from_local(spec, path, backup, stop_after_blocks=-1) catch {
    @host.InvalidInput(message) => assert_true(message.contains("budget"))
    _ => fail("lost negative-budget diagnostic")
  } noraise {
    _ => fail("accepted negative budget")
  }
  assert_true(!@fs.exists(path) && !@fs.exists(path + ".mfl.lock"))
  @fs.write_file(path, b"XXXXXXX")
  let checkpoint = audit_checkpoint(spec, data, [])
  @fs.write_file(path + ".mfl", checkpoint)
  @fs.write_file(path + ".mfl.lock", b"")
  @fs.write_file(backup, b"xxxxxxx")
  let signal = @ledger.PauseSignal::new()
  signal.request_pause()
  let events : Array[@host.LocalRepairProgress] = []
  try
    @host.repair_from_local(
      spec,
      path,
      backup,
      stop_after_blocks=0,
      pause_signal=signal,
      on_progress=event => events.push(event),
    )
  catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("lost bad-backup diagnostic")
  } noraise {
    _ => fail("pause bypassed source verification")
  }
  assert_true(events.is_empty())
  assert_eq(@fs.read_file(path).binary(), b"XXXXXXX")
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  @fs.write_file(backup, data)
  try
    @host.repair_from_local(spec, path, backup, on_progress=event => {
      events.push(event)
      if event.phase is @host.Recovered {
        @fs.write_file(backup, b"Xbcdefg")
      }
    })
  catch {
    @ledger.InvalidResponse(message) =>
      assert_true(message.contains("source changed"))
    _ => fail("lost changed-backup diagnostic")
  } noraise {
    _ => fail("copied modified backup bytes")
  }
  assert_eq(events.length(), 1)
  assert_eq(@fs.read_file(path).binary(), b"XXXXXXX")
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  @fs.write_file(backup, data)
  assert_true(@host.repair_from_local(spec, path, backup).complete)
}

///|
async test "local repair never emits completion for a damaged final target" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-final-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abc"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  @fs.write_file(backup, data)
  @host.adopt(spec, path, chunk_size=3)
  let events : Array[@host.LocalRepairProgress] = []
  try
    @host.repair_from_local(spec, path, backup, stop_after_blocks=0, on_progress=event => {
      events.push(event)
      if event.phase is @host.Recovered {
        @fs.write_file(path, b"Xbc")
      }
    })
  catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("lost final target integrity error")
  } noraise {
    _ => fail("reported completion without final verification")
  }
  assert_eq(events.length(), 1)
  assert_true(events[0].phase is @host.Recovered)
  assert_true(@host.repair_from_local(spec, path, backup).complete)
}
