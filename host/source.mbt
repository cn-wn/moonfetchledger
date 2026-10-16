///|
/// One bounded response from an external range source. Metadata describes the
/// actual response; receive_from checks it against the reserved lease before I/O.
pub(all) struct ReceivedBlock {
  bytes : Bytes
  status : Int32
  etag : String
  range : @ledger.ByteRange
  total : Int64
  content_encoding : String
}
