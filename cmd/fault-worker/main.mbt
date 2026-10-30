///|
fn block(data : Bytes, range : @ledger.ByteRange) -> @host.ReceivedBlock {
  {
    bytes: data[range.start.to_int():range.end.to_int()].to_owned(),
    status: 206,
    etag: "\"fault-v1\"",
    range,
    total: data.length().to_int64(),
    content_encoding: "identity",
  }
}

///|
async fn pending(
  spec : @ledger.ObjectSpec,
  data : Bytes,
  output : String,
) -> Unit {
  let session = @ledger.restore(@fs.read_file(output + ".mfl").text(), spec)
  let file = @fs.open(output, mode=ReadWrite)
  defer file.close()
  for range in session.recovery_ranges() {
    assert_true(
      session.reconcile_block(
        range,
        Some(
          file.read_exactly_at(range.length().to_int(), position=range.start),
        ),
      ),
    )
  }
  session.finish_recovery()
  let lease = session.reserve_missing().unwrap()
  assert_eq(lease.range.start, 4096L)
  let bytes = data[lease.range.start.to_int():lease.range.end.to_int()].to_owned()
  let prepared = session.prepare_chunk(
    lease,
    bytes,
    status=206,
    etag=spec.etag,
    range=lease.range,
    total=spec.length,
  )
  file.write_at(bytes, position=lease.range.start)
  file.sync()
  session.commit_written(
    prepared,
    file.read_exactly_at(bytes.length(), position=lease.range.start),
  )
  let next = @fs.open(
    output + ".mfl.next",
    mode=ReadWrite,
    create_mode=CreateNew,
  )
  defer next.close()
  next.write(session.checkpoint())
  next.sync()
}

///|
async fn holding(dir : String) -> Unit {
  @fs.write_file(
    dir + "/ready",
    b"ready-after-synced-state",
    create_mode=CreateNew,
  )
  while true {
    @async.sleep(1000)
  }
}

///|
async fn receive(
  spec : @ledger.ObjectSpec,
  data : Bytes,
  output : String,
) -> @host.DownloadReport {
  @host.receive_from(spec, output, chunk_size=4096, parallel=1, fetch_range=range => {
    block(data, range)
  })
}

///|
async fn main {
  let args = @env.args()
  if args.length() != 3 ||
    ![
      "saved", "pending", "resume", "recover-pending", "checkpoint-fail", "disk-full",
      "write-refusal", "batched", "resume-batched",
    ].contains(args[1]) {
    fail("fault-worker MODE OWNED_FIXTURE_DIRECTORY")
  }
  let mode = args[1]
  let dir = args[2]
  if @fs.read_file(dir + "/owner").binary() != b"MFLFAULT-DIRECTORY1" {
    fail("refusing unowned fault fixture directory")
  }
  let data = @fs.read_file(dir + "/publisher").binary()
  assert_eq(data.length(), 28008)
  assert_eq(
    @ledger.digest(data),
    "dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042",
  )
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/fault-target",
    data.length().to_int64(),
    "\"fault-v1\"",
    @ledger.digest(data),
  )
  let output = dir + "/staging"
  if mode == "batched" {
    ignore(
      @host.receive_from(
        spec,
        output,
        chunk_size=4096,
        parallel=1,
        checkpoint_blocks=4,
        fetch_range=range => {
          if range.start == 24576L {
            holding(dir)
          }
          block(data, range)
        },
      ),
    )
    fail("batched kill fixture unexpectedly completed")
  }
  if mode == "saved" || mode == "pending" {
    ignore(
      @host.receive_from(
        spec,
        output,
        chunk_size=4096,
        parallel=1,
        fetch_range=range => block(data, range),
        on_progress=progress => {
          if progress.phase is BlockCommitted(_) &&
            progress.downloaded_blocks == 1 {
            if mode == "pending" {
              pending(spec, data, output)
            }
            holding(dir)
          }
        },
      ),
    )
    fail("kill fixture unexpectedly completed")
  }
  if mode == "checkpoint-fail" {
    let mut reads = 0
    try
      @host.receive_from(
        spec,
        output,
        chunk_size=4096,
        parallel=1,
        fetch_range=range => {
          reads += 1
          block(data, range)
        },
        on_progress=progress => {
          if progress.phase is BlockCommitted(_) &&
            progress.downloaded_blocks == 1 {
            @fs.write_file(
              dir + "/saved",
              @fs.read_file(output + ".mfl").binary(),
              create_mode=CreateNew,
            )
            @fs.mkdir(output + ".mfl.next")
          }
        },
      )
    catch {
      _ => {
        assert_eq(reads, 2)
        assert_eq(@fs.kind(output + ".mfl.next"), Directory)
        assert_eq(
          @fs.read_file(output + ".mfl").binary(),
          @fs.read_file(dir + "/saved").binary(),
        )
        let file = @fs.open(output, mode=ReadOnly)
        defer file.close()
        assert_eq(
          file.read_exactly_at(8192, position=0L),
          data[:8192].to_owned(),
        )
      }
    } noraise {
      _ => fail("checkpoint installation failure was ignored")
    }
    @fs.rmdir(output + ".mfl.next")
  }
  if mode == "disk-full" || mode == "write-refusal" {
    if @env.get_env_var("OS") == Some("Windows_NT") || !@fs.exists("/dev/full") {
      fail("ENOSPC fixture requires Linux /dev/full")
    }
    ignore(
      @host.receive_from(spec, output, chunk_size=4096, stop_after_blocks=0, fetch_range=range => {
        block(data, range)
      }),
    )
    let checkpoint = @fs.read_file(output + ".mfl").binary()
    @fs.remove(output)
    let kernel_path = if mode == "disk-full" {
      "/dev/full"
    } else {
      "/proc/self/oom_score_adj"
    }
    let before_kernel = if mode == "write-refusal" {
      @fs.read_file(kernel_path).binary()
    } else {
      b""
    }
    if mode == "disk-full" {
      let full = @fs.open("/dev/full", mode=WriteOnly)
      defer full.close()
      try full.write(data) catch {
        error => {
          let diagnostic = "\{Repr(error)}"
          assert_true(
            diagnostic.contains("No space left on device") ||
            diagnostic.contains("ENOSPC"),
          )
        }
      } noraise {
        _ => fail("Linux /dev/full did not reject a sequential write")
      }
    }
    @fs.symlink(target=kernel_path, output)
    let mut reads = 0
    try
      @host.receive_from(spec, output, chunk_size=4096, parallel=1, fetch_range=range => {
        reads += 1
        block(data, range)
      })
    catch {
      error => {
        let diagnostic = "\{Repr(error)}"
        if mode == "disk-full" {
          assert_true(
            diagnostic.contains("receiver output must be a regular file"),
          )
        } else {
          if !(diagnostic.contains("Invalid argument") ||
            diagnostic.contains("EINVAL")) {
            fail(
              "expected kernel rejection of invalid text; actual diagnostic: " +
              diagnostic,
            )
          }
          assert_eq(@fs.read_file(kernel_path).binary(), before_kernel)
        }
        assert_eq(reads, if mode == "disk-full" { 0 } else { 1 })
        assert_eq(@fs.read_file(output + ".mfl").binary(), checkpoint)
      }
    } noraise {
      _ => fail("disk write failure was ignored")
    }
    @fs.remove(output) // Unlink only the owned fixture link, never its endpoint.
    @fs.write_file(output, b"", create_mode=CreateNew)
  }
  let before = if mode == "recover-pending" {
    let artifact = @fs.read_file(output).binary()
    let checkpoint = @fs.read_file(output + ".mfl").binary()
    let candidate = @fs.read_file(output + ".mfl.next").binary()
    try receive(spec, data, output) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong pending checkpoint refusal")
    } noraise {
      _ => fail("silently consumed pending state")
    }
    assert_eq(@fs.read_file(output).binary(), artifact)
    assert_eq(@fs.read_file(output + ".mfl").binary(), checkpoint)
    assert_eq(@fs.read_file(output + ".mfl.next").binary(), candidate)
    let recovered = @host.recover_checkpoint(spec, output)
    assert_eq(recovered.confirmed_bytes, 8192L)
    8192L
  } else if mode == "disk-full" || mode == "write-refusal" {
    0L
  } else if mode == "resume-batched" {
    assert_eq(@fs.read_file(output).binary().length(), 24576)
    16384L
  } else {
    4096L
  }
  let result = receive(spec, data, output)
  assert_true(result.complete)
  assert_eq(result.recovery.retained_bytes, before)
  assert_eq(@fs.read_file(output).binary(), data)
  assert_eq(@fs.read_file(dir + "/publisher").binary(), data)
  assert_eq(result.downloaded_blocks, 7 - (before / 4096L).to_int())
  println(
    Json::array([
      Json::string("MFLFAULT1"),
      Json::string(mode),
      Json::string(before.to_string()),
      Json::string(result.downloaded_blocks.to_string()),
      Json::string(@ledger.digest(@fs.read_file(output).binary())),
    ]).stringify(),
  )
}
