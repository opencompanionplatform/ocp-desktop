//! OS local-socket binding — ADR-0005 tier 2, RUNTIME_API §4.
//!
//! The core listens on a local socket (Unix domain socket / Windows named
//! pipe) and the runtime connects to it. This module is only the transport;
//! the framing + handshake + envelope validation come from the protocol layer
//! (crate root) and run unchanged over the returned streams.
//!
//! Peer authentication (SEC-040) in the alpha is the per-session token
//! handshake ([`crate::accept_handshake`] / [`crate::client_handshake`]): the
//! core mints a token at runtime launch (out-of-band, e.g. a 0600 file) and
//! only a peer presenting it completes the handshake. OS peer-credential
//! checks (SO_PEERCRED / named-pipe client identity, RUNTIME_API §4.1) are a
//! defense-in-depth follow-up; the token gate is sufficient and portable now.
//!
//! Cross-platform local sockets come from `interprocess` (CODING_STANDARD
//! dependency policy): std has Unix domain sockets but no Windows named pipes,
//! and re-implementing named pipes would need first-party `unsafe` FFI, which
//! SEC-042 forbids.

use std::{io, thread, time::Duration};

#[cfg(windows)]
use interprocess::local_socket::GenericFilePath;
#[cfg(not(windows))]
use interprocess::local_socket::GenericNamespaced;
use interprocess::local_socket::{prelude::*, ListenerOptions, Stream as LocalStream};

#[cfg(windows)]
use interprocess::os::windows::{
    local_socket::ListenerOptionsExt, security_descriptor::SecurityDescriptor,
};
#[cfg(windows)]
use widestring::U16CString;

use crate::{
    accept_handshake, accept_handshake_hello, client_handshake, client_handshake_with_intent,
    Hello, IpcError,
};

/// A connected local-socket stream. Implements `Read + Write`, so every
/// protocol-layer function (`send_envelope`, `recv_envelope`, framing) works
/// over it directly.
pub type Connection = LocalStream;

/// Bound receive waits so embedders can stop worker threads before unloading
/// the runtime module. This is especially important for Windows named pipes:
/// a detached thread must not remain blocked in Read while a GDExtension DLL
/// is being unloaded.
pub fn set_receive_timeout(connection: &Connection, timeout: Option<Duration>) -> io::Result<()> {
    connection.set_recv_timeout(timeout)
}

#[cfg(windows)]
fn local_pipe_security_descriptor() -> io::Result<SecurityDescriptor> {
    // The pipe remains local-only via interprocess' PIPE_REJECT_REMOTE_CLIENTS;
    // the protocol token is the actual peer authorization gate.  Use the
    // broad local access instead of OW because elevated/non-elevated processes
    // can have different owner SIDs on the same desktop. The pipe transport
    // rejects remote clients, and the protocol token remains mandatory.
    let sddl = U16CString::from_str("D:(A;;GA;;;WD)")
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid local pipe SDDL"))?;
    SecurityDescriptor::deserialize(&sddl)
}
/// Build the platform socket name. On Windows this becomes a named pipe
/// (`\\.\pipe\<name>`); on Unix an abstract/namespaced socket. Callers pass a
/// stable identifier such as `"ocp-runtime"`.
fn socket_name(name: &str) -> io::Result<interprocess::local_socket::Name<'static>> {
    #[cfg(windows)]
    return format!(r#"\\.\pipe\{name}"#)
        .to_fs_name::<GenericFilePath>()
        .map(|n| n.into_owned());

    #[cfg(not(windows))]
    name.to_string()
        .to_ns_name::<GenericNamespaced>()
        .map(|n| n.into_owned())
}

/// Core side: bind the local socket and listen. Fails if another process holds
/// the name (a second core, or a stale socket).
pub struct Listener {
    inner: interprocess::local_socket::Listener,
}

impl Listener {
    /// Bind `name` for incoming runtime connections.
    pub fn bind(name: &str) -> io::Result<Self> {
        let options = ListenerOptions::new().name(socket_name(name)?);
        #[cfg(windows)]
        let options = options.security_descriptor(local_pipe_security_descriptor()?);
        let listener = options.create_sync()?;
        Ok(Self { inner: listener })
    }

    /// Accept one raw connection (unauthenticated). Prefer
    /// [`Listener::accept_authenticated`] on the real path.
    pub fn accept(&self) -> io::Result<Connection> {
        self.inner.accept()
    }

    /// Accept a connection and run the SEC-040 token handshake before handing
    /// it back. On handshake failure the connection is dropped (closed) and the
    /// error returned — the caller keeps serving other peers.
    pub fn accept_authenticated(&self, token: &str) -> Result<Connection, IpcError> {
        let mut conn = self.inner.accept()?;
        accept_handshake(&mut conn, token)?;
        Ok(conn)
    }

    /// Like [`Listener::accept_authenticated`], but also returns the peer's
    /// `Hello` so the server can route on its declared `intent`.
    pub fn accept_authenticated_hello(&self, token: &str) -> Result<(Connection, Hello), IpcError> {
        let mut conn = self.inner.accept()?;
        let hello = accept_handshake_hello(&mut conn, token)?;
        Ok((conn, hello))
    }
}

/// Runtime side: connect to the core's local socket.
///
/// Windows named-pipe creation and the first client connect can race during
/// process startup. Retry only transient readiness errors; authentication is
/// still required before a connection is returned to callers.
pub fn connect(name: &str) -> io::Result<Connection> {
    const ATTEMPTS: usize = 20;
    const RETRY_DELAY: Duration = Duration::from_millis(10);
    let socket = socket_name(name)?;
    for attempt in 0..ATTEMPTS {
        match LocalStream::connect(socket.clone()) {
            Ok(connection) => return Ok(connection),
            Err(error)
                if attempt + 1 < ATTEMPTS
                    && matches!(
                        error.kind(),
                        io::ErrorKind::PermissionDenied | io::ErrorKind::NotFound
                    ) =>
            {
                thread::sleep(RETRY_DELAY)
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("the final connect attempt always returns")
}

/// Connect and complete the SEC-040 handshake, presenting `token`.
pub fn connect_authenticated(name: &str, token: &str) -> Result<Connection, IpcError> {
    let mut conn = connect(name)?;
    client_handshake(&mut conn, token)?;
    Ok(conn)
}

/// Connect, declaring a connection intent ([`crate::INTENT_SUBSCRIBE`] /
/// [`crate::INTENT_PUBLISH`]) in the handshake.
pub fn connect_authenticated_with_intent(
    name: &str,
    token: &str,
    intent: &str,
) -> Result<Connection, IpcError> {
    let mut conn = connect(name)?;
    client_handshake_with_intent(&mut conn, token, Some(intent))?;
    Ok(conn)
}
