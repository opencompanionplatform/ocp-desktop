use std::collections::{HashSet, VecDeque};
use std::io::{Read, Write};
use std::thread;

use ocp_llm_router::OsKeystoreCredentialStore;
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

const MAX_REQUEST_BYTES: u64 = 8_192;
const MAX_CREDENTIAL_LENGTH: usize = 4_096;
const MAX_REPLAY_IDS: usize = 256;
const PROVIDER_IDS: [&str; 2] = ["openai-compatible", "gemini-cloud"];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BrokerRequest {
    version: u8,
    #[serde(rename = "requestId")]
    request_id: String,
    capability: String,
    #[serde(rename = "providerId")]
    provider_id: String,
    credential: String,
}

#[derive(Debug, Serialize)]
struct BrokerResponse<'a> {
    version: u8,
    #[serde(rename = "requestId")]
    request_id: &'a str,
    ok: bool,
    code: &'a str,
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes()
        .iter()
        .zip(right.as_bytes())
        .fold(0_u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

fn valid_capability(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn safe_credential(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_CREDENTIAL_LENGTH
        && value.trim().len() == value.len()
        && !value.chars().any(char::is_control)
}

struct ReplayWindow {
    ids: HashSet<String>,
    order: VecDeque<String>,
}

impl ReplayWindow {
    fn new() -> Self {
        Self {
            ids: HashSet::new(),
            order: VecDeque::new(),
        }
    }

    fn insert(&mut self, request_id: &str) -> bool {
        if !self.ids.insert(request_id.to_owned()) {
            return false;
        }
        self.order.push_back(request_id.to_owned());
        while self.order.len() > MAX_REPLAY_IDS {
            if let Some(expired) = self.order.pop_front() {
                self.ids.remove(&expired);
            }
        }
        true
    }
}

fn process_request<F>(
    bytes: &mut Vec<u8>,
    session_capability: &str,
    replay: &mut ReplayWindow,
    mut store: F,
) -> Vec<u8>
where
    F: FnMut(&str, &str) -> Result<(), ()>,
{
    let parsed = serde_json::from_slice::<BrokerRequest>(bytes);
    bytes.zeroize();
    let Ok(mut request) = parsed else {
        return serde_json::to_vec(&BrokerResponse {
            version: 1,
            request_id: "",
            ok: false,
            code: "invalid-request",
        })
        .unwrap_or_default();
    };

    let request_id = request.request_id.clone();
    let response = if request.version != 1
        || !valid_capability(&request.capability)
        || !constant_time_equal(&request.capability, session_capability)
    {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: false,
            code: "authentication-failed",
        }
    } else if uuid::Uuid::parse_str(&request.request_id).is_err() {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: false,
            code: "invalid-request",
        }
    } else if !replay.insert(&request.request_id) {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: false,
            code: "replayed-request",
        }
    } else if !PROVIDER_IDS.contains(&request.provider_id.as_str())
        || !safe_credential(&request.credential)
    {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: false,
            code: "invalid-request",
        }
    } else if store(&request.provider_id, &request.credential).is_ok() {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: true,
            code: "stored",
        }
    } else {
        BrokerResponse {
            version: 1,
            request_id: &request_id,
            ok: false,
            code: "keystore-unavailable",
        }
    };
    request.capability.zeroize();
    request.credential.zeroize();
    serde_json::to_vec(&response).unwrap_or_default()
}

#[cfg(windows)]
mod platform {
    use super::*;
    use interprocess::local_socket::{prelude::*, GenericFilePath, ListenerOptions};
    use interprocess::os::windows::{
        local_socket::ListenerOptionsExt, security_descriptor::SecurityDescriptor,
    };
    use widestring::U16CString;

    fn owner_only_security_descriptor() -> std::io::Result<SecurityDescriptor> {
        let sddl = U16CString::from_str("D:(A;;GA;;;OW)").map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid broker ACL")
        })?;
        SecurityDescriptor::deserialize(&sddl)
    }

    fn socket_name(name: &str) -> std::io::Result<interprocess::local_socket::Name<'static>> {
        format!(r#"\\.\pipe\{name}"#)
            .to_fs_name::<GenericFilePath>()
            .map(|name| name.into_owned())
    }

    pub(super) fn start(pipe_name: String, capability: String) -> std::io::Result<()> {
        let listener = ListenerOptions::new()
            .name(socket_name(&pipe_name)?)
            .security_descriptor(owner_only_security_descriptor()?)
            .create_sync()?;
        thread::Builder::new()
            .name("ocp-credential-broker".to_owned())
            .spawn(move || {
                let mut replay = ReplayWindow::new();
                for connection in listener.incoming() {
                    let Ok(mut connection) = connection else {
                        continue;
                    };
                    let mut bytes = Vec::new();
                    if (&mut connection)
                        .take(MAX_REQUEST_BYTES + 1)
                        .read_to_end(&mut bytes)
                        .is_err()
                        || bytes.len() as u64 > MAX_REQUEST_BYTES
                    {
                        bytes.zeroize();
                        continue;
                    }
                    let response = process_request(
                        &mut bytes,
                        &capability,
                        &mut replay,
                        |provider_id, credential| {
                            OsKeystoreCredentialStore::new("ocp-ai-provider")
                                .set(provider_id, credential)
                                .map_err(|_| ())
                        },
                    );
                    let _ = connection.write_all(&response);
                    let _ = connection.flush();
                }
            })?;
        Ok(())
    }

    #[cfg(test)]
    pub(super) fn owner_acl_builds() -> bool {
        owner_only_security_descriptor().is_ok()
    }
}

pub struct CredentialBroker {
    pipe_name: String,
    capability: String,
}

impl CredentialBroker {
    pub fn start(pipe_name: String, capability: String) -> Option<Self> {
        if !valid_capability(&capability)
            || !pipe_name.starts_with("ocp-credential-")
            || pipe_name.len() != "ocp-credential-".len() + 32
            || !pipe_name["ocp-credential-".len()..]
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return None;
        }
        #[cfg(windows)]
        platform::start(pipe_name.clone(), capability.clone()).ok()?;
        #[cfg(not(windows))]
        return None;
        #[cfg(windows)]
        Some(Self {
            pipe_name,
            capability,
        })
    }

    pub fn launch_arguments(&self) -> [String; 2] {
        [
            format!("--ocp-credential-pipe={}", self.pipe_name),
            format!("--ocp-credential-capability={}", self.capability),
        ]
    }
}

impl Drop for CredentialBroker {
    fn drop(&mut self) {
        self.capability.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ocp_llm_router::CredentialStore;

    fn request(capability: &str, request_id: &str, provider_id: &str, credential: &str) -> Vec<u8> {
        serde_json::json!({
            "version": 1,
            "requestId": request_id,
            "capability": capability,
            "providerId": provider_id,
            "credential": credential,
        })
        .to_string()
        .into_bytes()
    }

    #[test]
    fn stores_allowlisted_credentials_and_never_echoes_secret_or_capability() {
        let capability = "a".repeat(64);
        let id = uuid::Uuid::now_v7().to_string();
        let mut input = request(&capability, &id, "gemini-cloud", "test-secret");
        let mut replay = ReplayWindow::new();
        let response = process_request(
            &mut input,
            &capability,
            &mut replay,
            |provider, credential| {
                assert_eq!(provider, "gemini-cloud");
                assert_eq!(credential, "test-secret");
                Ok(())
            },
        );
        let text = String::from_utf8(response).expect("response is utf8");
        assert!(text.contains("\"code\":\"stored\""));
        assert!(!text.contains("test-secret"));
        assert!(!text.contains(&capability));
        assert!(input.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn rejects_invalid_auth_replay_provider_and_size_without_storing() {
        let capability = "b".repeat(64);
        let id = uuid::Uuid::now_v7().to_string();
        let mut replay = ReplayWindow::new();
        let mut stored = 0;
        for (presented, request_id, provider, credential, expected) in [
            (
                "c".repeat(64),
                uuid::Uuid::now_v7().to_string(),
                "gemini-cloud",
                "key".to_owned(),
                "authentication-failed",
            ),
            (
                capability.clone(),
                id.clone(),
                "gemini-cloud",
                "key".to_owned(),
                "stored",
            ),
            (
                capability.clone(),
                id.clone(),
                "gemini-cloud",
                "key".to_owned(),
                "replayed-request",
            ),
            (
                capability.clone(),
                uuid::Uuid::now_v7().to_string(),
                "other",
                "key".to_owned(),
                "invalid-request",
            ),
            (
                capability.clone(),
                uuid::Uuid::now_v7().to_string(),
                "gemini-cloud",
                "x".repeat(MAX_CREDENTIAL_LENGTH + 1),
                "invalid-request",
            ),
        ] {
            let mut input = request(&presented, &request_id, provider, &credential);
            let response = process_request(&mut input, &capability, &mut replay, |_, _| {
                stored += 1;
                Ok(())
            });
            assert!(String::from_utf8(response).unwrap().contains(expected));
        }
        assert_eq!(stored, 1);
    }

    #[test]
    fn maps_missing_capability_and_keystore_failure_to_safe_codes() {
        let capability = "d".repeat(64);
        let mut replay = ReplayWindow::new();
        let mut missing = serde_json::json!({
            "version": 1,
            "requestId": uuid::Uuid::now_v7().to_string(),
            "providerId": "gemini-cloud",
            "credential": "test-key",
        })
        .to_string()
        .into_bytes();
        let missing_response =
            process_request(&mut missing, &capability, &mut replay, |_, _| Ok(()));
        assert!(String::from_utf8(missing_response)
            .unwrap()
            .contains("invalid-request"));

        let mut failing = request(
            &capability,
            &uuid::Uuid::now_v7().to_string(),
            "openai-compatible",
            "test-key",
        );
        let failure_response =
            process_request(&mut failing, &capability, &mut replay, |_, _| Err(()));
        assert!(String::from_utf8(failure_response)
            .unwrap()
            .contains("keystore-unavailable"));
    }

    #[cfg(windows)]
    #[test]
    fn owner_only_windows_descriptor_builds() {
        assert!(platform::owner_acl_builds());
    }

    #[cfg(windows)]
    #[test]
    fn disposable_windows_os_keystore_round_trip_is_real_and_cleaned() {
        let namespace = format!("ocp-g16-13b-test-{}", uuid::Uuid::now_v7());
        let store = OsKeystoreCredentialStore::new(&namespace);
        let mut secret = format!("test-{}", uuid::Uuid::now_v7());
        let stored = store.set("gemini-cloud", &secret).is_ok();
        let mut loaded = store.get("gemini-cloud").unwrap_or_default();
        let matched = constant_time_equal(&loaded, &secret);
        let removed = store.delete("gemini-cloud").is_ok() && store.get("gemini-cloud").is_none();
        loaded.zeroize();
        secret.zeroize();
        assert!(stored && matched && removed);
    }
}
