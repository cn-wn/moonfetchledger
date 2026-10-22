///|
fn main raise {
  // Public deterministic DEMONSTRATION seed only. Never use it for releases.
  let seed = Bytes::makei(32, i => i.to_byte())
  let announcement = @signed.Release::new(
    "earthquakes",
    "stable",
    2L,
    1792540800L,
    1795132800L,
    "https://example.test/earthquakes-v2.delta",
    @ledger.digest(b"example delta metadata"),
  )
  let trusted_key = @ed25519.derive_public_key(seed)
  let policy = @signed.ReleaseTrust::new(trusted_key, "earthquakes", "stable")
  let checked = policy.verify(announcement.sign(seed), 1792627200L)
  assert_eq(
    checked.release.metadata_sha256,
    @ledger.digest(b"example delta metadata"),
  )
  println(
    "verified signed release: product=earthquakes channel=stable version=\{checked.release.version}; metadata pin is bound to the pinned publisher",
  )
}
