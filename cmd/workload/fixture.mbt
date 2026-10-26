///|
// Deterministic SYNTHETIC workload, not a publisher dataset or crypto RNG.
struct Generator {
  mut state : UInt32
}

///|
fn Generator::take(self : Generator, length : Int32) -> Bytes {
  Bytes::makei(length, _ => {
    let mut n = self.state
    n = n ^ (n << 13)
    n = n ^ (n >> 17)
    n = n ^ (n << 5)
    self.state = n
    (n >> 24).reinterpret_as_int().to_byte()
  })
}

///|
async fn file_hash(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  let hasher = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let bytes = file.read_exactly_at(
      (size - offset).min(65536L).to_int(),
      position=offset,
    )
    hasher.update(bytes)
    continue offset + bytes.length().to_int64()
  }
  assert_eq(file.size(), size)
  @crypto.bytes_to_hex_string(hasher.finalize())
}

///|
struct Fixture {
  length : Int64
  sha256 : String
  seed_bytes : Int64
  seed_sha256 : String
  expected_reused : Int64
}

///|
async fn generate(
  dir : String,
  scenario : String,
  length : Int64,
  chunk : Int32,
) -> Fixture {
  let target = @fs.open(dir + "/target", mode=ReadWrite, create_mode=CreateNew)
  defer target.close()
  let seed = @fs.open(dir + "/seed", mode=ReadWrite, create_mode=CreateNew)
  defer seed.close()
  let generator : Generator = { state: 0x9E3779B9U, }
  let hasher = @crypto.SHA256::new()
  let mut source = 0L
  let mut reused = 0L
  if scenario == "shifted" {
    seed.write_at(b"prefix!", position=0L)
    source = 7L
  }
  for offset = 0L, index = 0; offset < length; {
    let bytes = generator.take((length - offset).min(chunk.to_int64()).to_int())
    target.write_at(bytes, position=offset)
    hasher.update(bytes)
    if scenario != "baseline" {
      if scenario == "reordered" {
        let count = length / chunk.to_int64()
        let position = if bytes.length() == chunk {
          (count - 1L - index.to_int64()) * chunk.to_int64()
        } else {
          offset
        }
        seed.write_at(bytes, position~)
        reused += bytes.length().to_int64()
      } else if scenario != "insert-delete" || index % 7 != 0 {
        if scenario == "insert-delete" && index % 5 == 0 {
          seed.write_at(b"inserted", position=source)
          source += 8L
        }
        let content = if scenario == "low-reuse" {
          Bytes::makei(bytes.length(), i => bytes[i] ^ 0xff)
        } else if scenario == "sparse" && index % 8 == 0 {
          Bytes::make(1, bytes[0] ^ 1) + bytes[1:].to_owned()
        } else {
          reused += bytes.length().to_int64()
          bytes
        }
        seed.write_at(content, position=source)
        source += content.length().to_int64()
      }
    }
    continue offset + bytes.length().to_int64(), index + 1
  }
  target.sync()
  seed.sync()
  {
    length,
    sha256: @crypto.bytes_to_hex_string(hasher.finalize()),
    seed_bytes: seed.size(),
    seed_sha256: file_hash(dir + "/seed"),
    expected_reused: reused,
  }
}
