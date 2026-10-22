///|
async test "preview is read-only agrees with reconstruction and refuses seed writers" {
  let dir = @fs.tmpdir(prefix="mfl-preview-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  let path = dir + "/old"
  @fs.write_file(path, b"!DEFabc")
  let files = @fs.readdir(dir)
  let metadata = @fs.read_file(dir + "/delta").binary()
  let plan = @host.preview_seed(reference, path)
  assert_eq(@host.preview_seed(reference, path).to_json(), plan.to_json())
  assert_eq(@fs.readdir(dir), files)
  assert_eq(@fs.read_file(path).binary(), b"!DEFabc")
  assert_eq(@fs.read_file(dir + "/delta").binary(), metadata)
  let actual = @host.reuse_from_seed(reference, path, dir + "/staging")
  assert_eq(plan.reused_bytes, actual.reused_bytes)
  assert_eq(plan.missing_ranges(), actual.missing_ranges)
  let writer = @fs.open(
    path + ".mfl.lock",
    mode=ReadWrite,
    create_mode=CreateNew,
  )
  assert_true(writer.try_lock(Exclusive))
  try @host.preview_seed(reference, path) catch {
    @host.OutputLocked => ()
    _ => fail("wrong preview lock refusal")
  } noraise {
    _ => fail("preview ignored seed writer")
  }
  writer.close()
  assert_eq(@host.preview_seed(reference, path).to_json(), plan.to_json())
}
