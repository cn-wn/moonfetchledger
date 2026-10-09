///|
test "pause intent is one-shot, idempotent and independent between invocations" {
  let signal = @moonfetchledger.PauseSignal::new()
  let other = @moonfetchledger.PauseSignal::new()
  assert_true(!signal.is_requested())
  assert_true(!other.is_requested())
  signal.request_pause()
  signal.request_pause()
  assert_true(signal.is_requested())
  assert_true(!other.is_requested())
}
