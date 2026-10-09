///|
/// One-shot cooperative pause intent. Serialize access on the application's
/// async scheduler; this is not an OS-thread synchronization primitive.
pub struct PauseSignal {
  priv mut requested : Bool
}

///|
pub fn PauseSignal::new() -> PauseSignal {
  { requested: false, }
}

///|
/// Request a pause without throwing or cancelling in-flight storage operations.
/// Repeating this request is harmless. Create a fresh signal to resume.
pub fn PauseSignal::request_pause(self : PauseSignal) -> Unit {
  self.requested = true
}

///|
pub fn PauseSignal::is_requested(self : PauseSignal) -> Bool {
  self.requested
}
