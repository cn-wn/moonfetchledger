///|
fn assert_enospc(error : Error) -> Unit raise {
  guard error is @os_error.OSError(28, context=_) else {
    fail("expected Linux ENOSPC from ordinary filesystem, got \{Repr(error)}")
  }
}

///|
// A bounded ext4 image belongs to the parent driver. Data-sync writes force
// allocation now; this never fills the host filesystem or a production volume.
async fn fill_volume(volume : String) -> Unit {
  let filler = @fs.open(
    volume + "/filler",
    mode=WriteOnly,
    create_mode=CreateNew,
    sync=Data,
  )
  defer filler.close()
  let bytes = Bytes::make(4096, b'x')
  for _ in 0..<4096 {
    filler.write(bytes) catch {
      error => {
        assert_enospc(error)
        return
      }
    }
  }
  fail("owned 16 MiB filesystem did not exhaust its allocation budget")
}

///|
async fn filesystem_fault(
  mode : String,
  dir : String,
  spec : @ledger.ObjectSpec,
  data : Bytes,
) -> Unit {
  let volume = dir + "/volume"
  assert_eq(@fs.read_file(volume + "/owner").binary(), b"MFL-EXT4-FIXTURE1")
  let output = volume + "/staging"
  let saved = dir + "/saved"
  if mode == "fs-data-full" {
    let mut reads = 0
    try
      @host.receive_from(spec, output, chunk_size=4096, parallel=1, fetch_range=r => {
        reads += 1
        assert_eq(reads, 1)
        @fs.write_file(
          saved,
          @fs.read_file(output + ".mfl").binary(),
          create_mode=CreateNew,
        )
        fill_volume(volume)
        block(data, r)
      })
    catch {
      error => assert_enospc(error)
    } noraise {
      _ => fail("ordinary-file ENOSPC during content write was ignored")
    }
    assert_eq(reads, 1)
    assert_eq(@fs.file_size(output), 0L)
  } else if mode == "fs-checkpoint-full" {
    ignore(
      @host.receive_from(
        spec,
        output,
        chunk_size=4096,
        parallel=1,
        stop_after_blocks=1,
        fetch_range=r => block(data, r),
      ),
    )
    @fs.write_file(
      saved,
      @fs.read_file(output + ".mfl").binary(),
      create_mode=CreateNew,
    )
    fill_volume(volume)
    let mut reads = 0
    try
      @host.receive_from(spec, output, fetch_range=r => {
        reads += 1
        block(data, r)
      })
    catch {
      error => assert_enospc(error)
    } noraise {
      _ => fail("ordinary-filesystem checkpoint ENOSPC was ignored")
    }
    assert_eq(reads, 0)
    assert_eq(@fs.read_file(output).binary(), data[:4096].to_owned())
  } else if mode == "fs-export-full" {
    assert_true(receive(spec, data, output).complete)
    @fs.write_file(
      saved,
      @fs.read_file(output + ".mfl").binary(),
      create_mode=CreateNew,
    )
    fill_volume(volume)
    try @host.export_verified(spec, output, volume + "/ready") catch {
      error => assert_enospc(error)
    } noraise {
      _ => fail("ordinary-filesystem export ENOSPC was ignored")
    }
    assert_true(
      !@fs.exists(volume + "/ready") && !@fs.exists(volume + "/ready.next"),
    )
    assert_eq(@fs.read_file(output).binary(), data)
  } else {
    let result = receive(spec, data, output)
    assert_true(result.complete)
    let expected = if mode == "fs-resume-data" {
      0L
    } else if mode == "fs-resume-checkpoint" {
      4096L
    } else {
      spec.length
    }
    assert_eq(result.recovery.retained_bytes, expected)
    assert_eq(
      result.downloaded_blocks,
      if expected == spec.length {
        0
      } else {
        7 - (expected / 4096L).to_int()
      },
    )
    @host.export_verified(spec, output, volume + "/ready")
    assert_eq(@fs.read_file(volume + "/ready").binary(), data)
    assert_eq(@fs.read_file(output).binary(), data)
    println(
      Json::array([
        Json::string("MFLFILESYSTEM1"),
        Json::string(mode),
        Json::string(expected.to_string()),
        Json::string(result.downloaded_blocks.to_string()),
        Json::string(@ledger.digest(data)),
      ]).stringify(),
    )
    return
  }
  assert_eq(
    @fs.read_file(output + ".mfl").binary(),
    @fs.read_file(saved).binary(),
  )
  assert_true(!@fs.exists(output + ".mfl.next"))
  assert_eq(@fs.kind(output), Regular)
  println(
    "ordinary ext4 ENOSPC observed; prior checkpoint and publisher retained: " +
    mode,
  )
}
