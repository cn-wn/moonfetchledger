///|
suberror BatchSourceFailed

///|
async test "batched source or checkpoint failure retains only installed coverage and retries unrecorded writes" {
  let dir = @fs.tmpdir(prefix="mfl-batch-error-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefghij"
  let spec = audit_spec(data)
  for failing_save in [false, true] {
    let output = dir + "/" + failing_save.to_string()
    let mut last_saved = 0L
    try
      @host.receive_from(
        spec,
        output,
        chunk_size=1,
        parallel=1,
        checkpoint_blocks=4,
        fetch_range=r => {
          if !failing_save && r.start == 6L {
            raise BatchSourceFailed
          }
          {
            bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
            status: 206,
            etag: spec.etag,
            range: r,
            total: spec.length,
            content_encoding: "identity",
          }
        },
        on_progress=e => {
          if e.phase is @host.BlockCommitted(_) {
            last_saved = e.confirmed_bytes
            if failing_save && !@fs.exists(output + ".mfl.next") {
              @fs.mkdir(output + ".mfl.next")
            }
          }
        },
      )
    catch {
      error => if !failing_save { assert_true(error is BatchSourceFailed) }
    } noraise {
      _ => fail("ignored batch failure")
    }
    assert_eq(last_saved, 4L)
    let old = @ledger.restore(@fs.read_file(output + ".mfl").text(), spec)
    assert_eq(old.recovery_ranges().length(), 4)
    if failing_save {
      @fs.rmdir(output + ".mfl.next")
    }
    let result = @host.receive_from(spec, output, checkpoint_blocks=4, fetch_range=r => {
      assert_true(r.start >= 4L)
      {
        bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
        status: 206,
        etag: spec.etag,
        range: r,
        total: spec.length,
        content_encoding: "identity",
      }
    })
    assert_true(result.complete)
    assert_eq(result.recovery.retained_bytes, 4L)
    assert_eq(result.downloaded_blocks, 6)
    assert_eq(@fs.read_file(output).binary(), data)
  }
}

///|
async test "batched reception saves a partial tail before pause and resumes only missing blocks" {
  let dir = @fs.tmpdir(prefix="mfl-batch-receive-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefghij"
  let spec = audit_spec(data)
  let output = dir + "/out"
  let saved : Array[Int64] = []
  let first = @host.receive_from(
    spec,
    output,
    chunk_size=1,
    parallel=1,
    checkpoint_blocks=4,
    stop_after_blocks=6,
    fetch_range=r => {
      bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
      status: 206,
      etag: spec.etag,
      range: r,
      total: spec.length,
      content_encoding: "identity",
    },
    on_progress=e => {
      if e.phase is @host.BlockCommitted(_) {
        let restored = @ledger.restore(
          @fs.read_file(output + ".mfl").text(),
          spec,
        )
        assert_eq(
          restored.recovery_ranges().length().to_int64(),
          e.confirmed_bytes,
        )
        saved.push(e.confirmed_bytes)
      }
    },
  )
  assert_true(!first.complete)
  assert_eq(saved, [4L, 4L, 4L, 4L, 6L, 6L])
  let second = @host.receive_from(spec, output, checkpoint_blocks=4, fetch_range=r => {
    assert_true(r.start >= 6L)
    {
      bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
      status: 206,
      etag: spec.etag,
      range: r,
      total: spec.length,
      content_encoding: "identity",
    }
  })
  assert_true(second.complete)
  assert_eq(second.recovery.retained_bytes, 6L)
  assert_eq(second.downloaded_blocks, 4)
  assert_eq(@fs.read_file(output).binary(), data)
  for n in [0, 1025] {
    try
      @host.receive_from(spec, dir + "/invalid", checkpoint_blocks=n, fetch_range=_ => {
        fail("unexpected source")
      })
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong batch limit error")
    } noraise {
      _ => fail("accepted bad batch limit")
    }
    assert_true(!@fs.exists(dir + "/invalid.mfl.lock"))
  }
}
