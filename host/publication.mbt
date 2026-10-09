///|
// CreateNew protects pre-existing temporary files; no-replace rename protects a
// pre-existing destination even if it appears after an initial existence check.
// Cleanup is registered only after this invocation creates its own temporary file.
async fn publish_new(path : String, write : async (@fs.File) -> Unit) -> Unit {
  let temporary = path + ".next"
  let file = @fs.open(temporary, mode=ReadWrite, create_mode=CreateNew)
  let mut published = false
  defer {
    file.close()
    if !published && @fs.exists(temporary) {
      @fs.remove(temporary)
    }
  }
  write(file)
  file.sync()
  file.close()
  @fs.rename(temporary, path, replace=false)
  published = true
}
