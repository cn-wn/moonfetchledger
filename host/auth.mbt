///|
/// Transient Bearer credential bound to one exact resource. No public secret
/// field, Debug implementation or serialization. It is never checkpointed.
pub struct BearerAuth {
  priv resource : String
  priv token : String
}

///|
/// Use HTTPS with system certificate verification. The explicit loopback option
/// permits only http://127.0.0.1 for local tests. Unsupported URL/token forms are
/// refused without echoing input. Obtain/refresh credentials outside this library.
pub fn BearerAuth::new(
  resource : String,
  token : String,
  allow_loopback_http? : Bool = false,
) -> BearerAuth raise HostError {
  if token.is_empty() || token.length() > 4096 {
    raise InvalidInput("Bearer token must contain 1..4096 ASCII characters")
  }
  let mut padding = false
  let mut base = false
  for c in token {
    if c == '=' && base {
      padding = true
    } else if !padding &&
      (
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '.' ||
        c == '_' ||
        c == '~' ||
        c == '+' ||
        c == '/'
      ) {
      base = true
    } else {
      raise InvalidInput("Bearer token has unsupported characters or padding")
    }
  }
  if resource.is_empty() || resource.length() > 8192 {
    raise InvalidInput(
      "authenticated resource must contain 1..8192 ASCII characters",
    )
  }
  for c in resource {
    if c.to_int() < 33 || c.to_int() > 126 || c == '#' || c == '\\' {
      raise InvalidInput(
        "authenticated URL requires ASCII without spaces, controls, fragments or backslashes",
      )
    }
  }
  let https = resource.has_prefix("https://")
  if !https && !resource.has_prefix("http://") {
    raise InvalidInput("authenticated URL must use HTTPS")
  }
  let offset = if https { 8 } else { 7 }
  let authority = resource[offset:].split("/").collect()[0]
  let parts = authority.split(":").collect()
  if parts.length() < 1 || parts.length() > 2 || parts[0].is_empty() {
    raise InvalidInput(
      "authenticated URL requires an ASCII DNS/IPv4 host; IPv6 authority unsupported",
    )
  }
  let host = parts[0]
  if host.length() > 253 {
    raise InvalidInput("authenticated hostname too long")
  }
  for label in host.split(".") {
    if label.is_empty() ||
      label.length() > 63 ||
      label.has_prefix("-") ||
      label.has_suffix("-") {
      raise InvalidInput("authenticated URL has an unsupported hostname")
    }
    for c in label {
      if !((c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-') {
        raise InvalidInput(
          "authenticated URL forbids userinfo and non-DNS host characters",
        )
      }
    }
  }
  if parts.length() == 2 {
    let port = number(parts[1]) catch {
      _ =>
        raise InvalidInput(
          "authenticated URL port requires a canonical decimal integer",
        )
    }
    if port < 1L || port > 65535L {
      raise InvalidInput("authenticated URL port must be 1..65535")
    }
  }
  if !https && (!allow_loopback_http || host != "127.0.0.1") {
    raise InvalidInput(
      "Bearer requests require HTTPS; only explicit 127.0.0.1 loopback HTTP is allowed for testing",
    )
  }
  { resource, token, }
}

///|
fn BearerAuth::check_resource(
  self : BearerAuth,
  resource : String,
) -> Unit raise HostError {
  if self.resource != resource {
    raise InvalidInput("Bearer credential is bound to a different resource")
  }
}
