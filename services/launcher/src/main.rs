#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(not(windows))]
fn main() {
    eprintln!("ocp-launcher is supported on Windows only");
}

#[cfg(windows)]
mod windows_launcher {
    use semver::Version;
    use serde::Deserialize;
    use std::collections::BTreeMap;
    use std::env;
    use std::ffi::OsStr;
    use std::fs::{self, OpenOptions};
    use std::io::{self, Read, Write};
    use std::net::{SocketAddr, TcpStream};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, ExitStatus};
    use std::thread;
    use std::time::{Duration, Instant};
    use url::Url;
    use uuid::Uuid;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegOpenKeyExW, RegQueryValueExW, HKEY_CURRENT_USER, KEY_READ, REG_DWORD,
        REG_SZ,
    };
    use windows_sys::Win32::System::Threading::{
        CreateMutexW, OpenProcess, QueryFullProcessImageNameW, TerminateProcess, CREATE_NO_WINDOW,
        PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK};

    const MUTEX_NAME: &str = "Local\\OpenCompanionPlatform.NativeLauncher";
    const MANAGED_ENV: &[&str] = &[
        "OCP_IPC_SOCKET",
        "OCP_IPC_TOKEN",
        "OCP_NATIVE_HOST_HANDOFF_PATH",
        "OCP_NATIVE_HOST_EVENT_PATH",
        "OCP_NATIVE_HOST_COMMAND_PATH",
        "OCP_NATIVE_HOST_UI_COMMAND_PATH",
        "OCP_NATIVE_HOST_BUBBLE_PATH",
        "OCP_NATIVE_HOST_TOKEN",
        "OCP_NATIVE_HOST_EMBED",
        "OCP_NATIVE_HOST_SIZE",
        "OCP_NATIVE_HOST_HITBOX",
        "OCP_NATIVE_INTERACTIVE",
        "OCP_NATIVE_PRODUCTION_ENABLED",
        "OCP_PRESENTATION_MODE",
        "OCP_DESKTOP_SHELL_ENABLED",
        "OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER",
        "OCP_DESKTOP_SHELL_EXECUTABLE",
        "OCP_DESKTOP_SHELL_ROOT",
        "OCP_STORE_LOOPBACK_ORIGINS",
        "OCP_STORE_URL",
        "OCP_UPDATER_EXE",
        "OCP_UPDATE_STAGING_DIR",
        "OCP_UPDATE_APPLY_SCRIPT",
        "OCP_UPDATE_INSTALL_ROOT",
        "OCP_UPDATE_START_SCRIPT",
        "OCP_UPDATE_STATUS_FILE",
        "OCP_UPDATE_HEALTH_FILE",
        "OCP_UPDATE_EXPECTED_VERSION",
        "OCP_UPDATE_PEER_PROCESS_IDS",
        "OCP_UPDATE_MANIFEST_URL",
        "OCP_UPDATE_KEY_ID",
        "OCP_UPDATE_PUBLIC_KEY_B64",
        "OCP_UPDATE_AUTOMATIC_CHECKS",
        "OCP_RUNTIME_VERSION",
        "OCP_HTTPS_PROXY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "http_proxy",
        "https_proxy",
        "NO_PROXY",
        "no_proxy",
    ];

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct BuildInfo {
        version: Option<String>,
        store_origin: Option<String>,
        update_manifest_url: Option<String>,
        update_key_id: Option<String>,
        update_public_key_base64: Option<String>,
        update_preview_manifest_url: Option<String>,
        update_preview_key_id: Option<String>,
        update_preview_public_key_base64: Option<String>,
        automatic_update_checks: Option<bool>,
        stable_update_trust_ready: Option<bool>,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct InstallHandoff {
        package_id: String,
        version: String,
        grant: String,
    }

    #[derive(Debug, Clone)]
    struct UpdateConfig {
        manifest_url: Option<String>,
        key_id: Option<String>,
        public_key_base64: Option<String>,
        preview_manifest_url: Option<String>,
        preview_key_id: Option<String>,
        preview_public_key_base64: Option<String>,
        automatic_checks: bool,
        stable_trust_ready: bool,
    }

    fn parse_build_info(raw: &str) -> Result<BuildInfo, String> {
        // PowerShell 5 `Set-Content -Encoding UTF8` and some Windows tooling
        // emit an UTF-8 BOM. JSON permits Unicode text, but serde_json expects
        // the first token rather than U+FEFF. Accept exactly one leading BOM
        // so upgrade metadata remains interoperable without weakening parsing.
        let normalized = raw.strip_prefix('\u{feff}').unwrap_or(raw);
        serde_json::from_str(normalized).map_err(|e| format!("BUILD-INFO.json is invalid: {e}"))
    }

    struct NamedMutex(HANDLE);
    impl Drop for NamedMutex {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CloseHandle(self.0) };
            }
        }
    }

    #[derive(Clone)]
    struct Layout {
        root: PathBuf,
        kernel: PathBuf,
        native: PathBuf,
        updater: PathBuf,
        apply_source: PathBuf,
        runtime: PathBuf,
        pck: PathBuf,
        shell_root: PathBuf,
        shell: PathBuf,
        build_info: PathBuf,
        log_root: PathBuf,
        update_root: PathBuf,
        updater_root: PathBuf,
        apply_helper: PathBuf,
        update_status: PathBuf,
        update_health: PathBuf,
        launcher: PathBuf,
        start_script: PathBuf,
    }

    struct TempFiles {
        paths: Vec<PathBuf>,
    }
    impl Drop for TempFiles {
        fn drop(&mut self) {
            for path in &self.paths {
                let _ = fs::remove_file(path);
            }
        }
    }

    struct LauncherLog {
        path: PathBuf,
    }
    impl LauncherLog {
        fn write(&self, message: impl AsRef<str>) {
            if let Ok(mut file) = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.path)
            {
                let _ = writeln!(file, "{}", message.as_ref());
            }
        }
    }

    fn wide(value: &OsStr) -> Vec<u16> {
        value.encode_wide().chain(std::iter::once(0)).collect()
    }

    fn show_error(message: &str) {
        let title = wide(OsStr::new("Open Companion Platform"));
        let body = wide(OsStr::new(message));
        unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                body.as_ptr(),
                title.as_ptr(),
                MB_OK | MB_ICONERROR,
            );
        }
    }

    fn acquire_launcher_mutex() -> io::Result<(NamedMutex, bool)> {
        let name = wide(OsStr::new(MUTEX_NAME));
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let already_exists = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        Ok((NamedMutex(handle), already_exists))
    }

    fn normalize_path(path: &Path) -> String {
        let mut value = path.to_string_lossy().replace('/', "\\").to_lowercase();
        if let Some(stripped) = value.strip_prefix("\\\\?\\") {
            value = stripped.to_owned();
        }
        value
    }

    fn process_image_path(pid: u32) -> Option<PathBuf> {
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if handle.is_null() {
            return None;
        }
        let mut buffer = vec![0u16; 32_768];
        let mut len = buffer.len() as u32;
        let ok =
            unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut len) } != 0;
        unsafe { CloseHandle(handle) };
        ok.then(|| PathBuf::from(String::from_utf16_lossy(&buffer[..len as usize])))
    }

    fn process_ids_by_path(path: &Path) -> Vec<u32> {
        let target = normalize_path(path);
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return Vec::new();
        }
        let mut result = Vec::new();
        let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut ok = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
        while ok {
            let pid = entry.th32ProcessID;
            if pid != 0 {
                if let Some(candidate) = process_image_path(pid) {
                    if normalize_path(&candidate) == target {
                        result.push(pid);
                    }
                }
            }
            ok = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
        }
        unsafe { CloseHandle(snapshot) };
        result
    }

    fn terminate_processes_by_path(path: &Path) {
        for pid in process_ids_by_path(path) {
            let handle = unsafe {
                OpenProcess(
                    PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
                    0,
                    pid,
                )
            };
            if !handle.is_null() {
                unsafe {
                    TerminateProcess(handle, 0);
                    CloseHandle(handle);
                }
            }
        }
    }

    fn layout() -> Result<Layout, String> {
        let exe = env::current_exe().map_err(|e| format!("Cannot resolve launcher path: {e}"))?;
        let root = exe
            .parent()
            .ok_or_else(|| "Launcher has no installation directory".to_owned())?
            .to_path_buf();
        let local = env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .ok_or_else(|| "LOCALAPPDATA is unavailable".to_owned())?;
        let data = local.join("OCP");
        let update_root = data.join("updates");
        let updater_root = data.join("updater");
        Ok(Layout {
            kernel: root.join("bin").join("ocp-kernel.exe"),
            native: root.join("bin").join("ocp-native-companion-window.exe"),
            updater: root.join("bin").join("ocp-release-check.exe"),
            apply_source: root.join("Apply-OcpUpdate.ps1"),
            runtime: root.join("ocp-runtime.exe"),
            pck: root.join("ocp-runtime.pck"),
            shell_root: root.join("desktop-shell"),
            shell: root.join("desktop-shell").join("OCP.exe"),
            build_info: root.join("BUILD-INFO.json"),
            log_root: data.join("logs"),
            update_status: update_root.join("ocp-update-status.json"),
            update_health: update_root.join("startup-ok.json"),
            apply_helper: updater_root.join("Apply-OcpUpdate.ps1"),
            update_root,
            updater_root,
            launcher: root.join("ocp-launcher.exe"),
            start_script: root.join("Start-OCP.ps1"),
            root,
        })
    }

    fn validate_layout(layout: &Layout) -> Result<(), String> {
        for path in [
            &layout.kernel,
            &layout.native,
            &layout.updater,
            &layout.apply_source,
            &layout.runtime,
            &layout.pck,
            &layout.shell,
            &layout.build_info,
            &layout.launcher,
            &layout.start_script,
        ] {
            if !path.is_file() {
                return Err(format!(
                    "OCP installation file is missing: {}",
                    path.display()
                ));
            }
        }
        Ok(())
    }

    fn parse_protocol_uri() -> Result<Option<String>, String> {
        let args: Vec<String> = env::args().skip(1).collect();
        let value = if args.len() >= 2 && args[0].eq_ignore_ascii_case("--protocol-uri") {
            Some(args[1].clone())
        } else {
            args.iter().find(|arg| arg.starts_with("ocp://")).cloned()
        };
        let Some(value) = value else { return Ok(None) };
        if value.len() > 4096 {
            return Err("Protocol URI is too long".to_owned());
        }
        let parsed = Url::parse(&value).map_err(|_| "Protocol URI is malformed".to_owned())?;
        if parsed.scheme() != "ocp" {
            return Err("Protocol URI must use ocp://".to_owned());
        }
        Ok(Some(parsed.to_string()))
    }

    fn valid_package_id(value: &str) -> bool {
        let mut segments = value.split('.');
        let Some(first) = segments.next() else {
            return false;
        };
        if first.is_empty()
            || !first.as_bytes()[0].is_ascii_lowercase()
            || !first
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return false;
        }
        let rest: Vec<&str> = segments.collect();
        !rest.is_empty()
            && rest.iter().all(|segment| {
                !segment.is_empty()
                    && (segment.as_bytes()[0].is_ascii_lowercase()
                        || segment.as_bytes()[0].is_ascii_digit())
                    && segment.bytes().all(|byte| {
                        byte.is_ascii_lowercase()
                            || byte.is_ascii_digit()
                            || matches!(byte, b'-' | b'_')
                    })
            })
    }

    fn valid_install_grant(value: &str) -> bool {
        (43..=128).contains(&value.len())
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    }

    fn parse_install_handoff_uri(value: &str) -> Result<Option<InstallHandoff>, String> {
        let parsed = Url::parse(value).map_err(|_| "Protocol URI is malformed".to_owned())?;
        if parsed.scheme() != "ocp" || parsed.host_str() != Some("install") {
            return Ok(None);
        }
        if !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.port().is_some()
            || parsed.fragment().is_some()
        {
            return Err("Install protocol URI contains unsupported authority data".to_owned());
        }
        let package_id = parsed.path().trim_start_matches('/');
        if package_id.contains('%') || !valid_package_id(package_id) {
            return Err("Install protocol package id is invalid".to_owned());
        }

        let pairs: Vec<(String, String)> = parsed
            .query_pairs()
            .map(|(key, value)| (key.into_owned(), value.into_owned()))
            .collect();
        if pairs.len() != 2 {
            return Err("Install protocol query is invalid".to_owned());
        }
        let mut version = None;
        let mut grant = None;
        for (key, value) in pairs {
            match key.as_str() {
                "version" if version.is_none() => version = Some(value),
                "grant" if grant.is_none() => grant = Some(value),
                _ => return Err("Install protocol query is invalid".to_owned()),
            }
        }
        let version = version.ok_or_else(|| "Install protocol version is missing".to_owned())?;
        let grant = grant.ok_or_else(|| "Install protocol grant is missing".to_owned())?;
        if version.len() > 96 || Version::parse(&version).is_err() {
            return Err("Install protocol version is invalid".to_owned());
        }
        if !valid_install_grant(&grant) {
            return Err("Install protocol grant is invalid".to_owned());
        }
        Ok(Some(InstallHandoff {
            package_id: package_id.to_owned(),
            version,
            grant,
        }))
    }

    fn parse_open_home_request() -> bool {
        env::args().skip(1).any(|arg| {
            arg.eq_ignore_ascii_case("--open=home") || arg.eq_ignore_ascii_case("--open-home")
        })
    }

    fn load_build_info(layout: &Layout) -> Result<BuildInfo, String> {
        let raw = fs::read_to_string(&layout.build_info)
            .map_err(|e| format!("Cannot read BUILD-INFO.json: {e}"))?;
        parse_build_info(&raw)
    }

    fn runtime_version_from_info(info: &BuildInfo) -> Result<Option<String>, String> {
        let Some(value) = info
            .version
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return Ok(None);
        };
        if value.len() > 96 || Version::parse(value).is_err() {
            return Err("BUILD-INFO version must be valid SemVer".to_owned());
        }
        Ok(Some(value.to_owned()))
    }

    fn load_runtime_version(layout: &Layout) -> Result<Option<String>, String> {
        let info = load_build_info(layout)?;
        runtime_version_from_info(&info)
    }

    fn normalize_https_url(value: &str, field: &str) -> Result<String, String> {
        let url = Url::parse(value.trim()).map_err(|_| format!("BUILD-INFO {field} is invalid"))?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(format!(
                "BUILD-INFO {field} must be an HTTPS URL without credentials or fragment"
            ));
        }
        Ok(url.to_string())
    }

    fn load_store_origin(layout: &Layout) -> Result<Option<String>, String> {
        let info = load_build_info(layout)?;
        let Some(origin) = info.store_origin.filter(|value| !value.trim().is_empty()) else {
            return Ok(None);
        };
        let url = Url::parse(origin.trim())
            .map_err(|_| "BUILD-INFO storeOrigin is invalid".to_owned())?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return Err("BUILD-INFO storeOrigin must be HTTPS without credentials".to_owned());
        }
        let host = url.host_str().unwrap_or_default();
        let mut normalized = format!("https://{host}");
        if let Some(port) = url.port() {
            normalized.push(':');
            normalized.push_str(&port.to_string());
        }
        Ok(Some(normalized))
    }

    fn update_config_from_info(info: &BuildInfo) -> Result<Option<UpdateConfig>, String> {
        let parse_config = |manifest: Option<&str>,
                            key_id: Option<&str>,
                            public_key: Option<&str>,
                            label: &str|
         -> Result<Option<(String, String, String)>, String> {
            let manifest = manifest.unwrap_or("").trim();
            let key_id = key_id.unwrap_or("").trim();
            let public_key = public_key.unwrap_or("").trim();
            let configured = !manifest.is_empty() || !key_id.is_empty() || !public_key.is_empty();
            if !configured {
                return Ok(None);
            }
            if manifest.is_empty() || key_id.is_empty() || public_key.is_empty() {
                return Err(format!(
                    "BUILD-INFO {label} update configuration is incomplete"
                ));
            }
            let manifest_url =
                normalize_https_url(manifest, &format!("{label} update manifest URL"))?;
            if key_id.len() > 128
                || !key_id.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-')
                })
            {
                return Err(format!(
                    "BUILD-INFO {label} update key ID contains unsupported characters"
                ));
            }
            if public_key.len() != 44
                || !public_key.ends_with('=')
                || !public_key
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
            {
                return Err(format!(
                    "BUILD-INFO {label} update public key is not a canonical Ed25519 public key"
                ));
            }
            Ok(Some((
                manifest_url,
                key_id.to_owned(),
                public_key.to_owned(),
            )))
        };

        let stable = parse_config(
            info.update_manifest_url.as_deref(),
            info.update_key_id.as_deref(),
            info.update_public_key_base64.as_deref(),
            "stable",
        )?;
        let preview = parse_config(
            info.update_preview_manifest_url.as_deref(),
            info.update_preview_key_id.as_deref(),
            info.update_preview_public_key_base64.as_deref(),
            "preview",
        )?;
        if stable.is_none() && preview.is_none() {
            if info.automatic_update_checks.unwrap_or(false) {
                return Err("BUILD-INFO enables automatic update checks without pinned update configuration".to_owned());
            }
            return Ok(None);
        }
        let (manifest_url, key_id, public_key_base64) = stable
            .map(|(url, id, key)| (Some(url), Some(id), Some(key)))
            .unwrap_or((None, None, None));
        let (preview_manifest_url, preview_key_id, preview_public_key_base64) = preview
            .map(|(url, id, key)| (Some(url), Some(id), Some(key)))
            .unwrap_or((None, None, None));
        Ok(Some(UpdateConfig {
            manifest_url,
            key_id,
            public_key_base64,
            preview_manifest_url,
            preview_key_id,
            preview_public_key_base64,
            automatic_checks: info.automatic_update_checks.unwrap_or(false),
            stable_trust_ready: info.stable_update_trust_ready.unwrap_or(false),
        }))
    }

    fn load_update_config(layout: &Layout) -> Result<Option<UpdateConfig>, String> {
        let info = load_build_info(layout)?;
        update_config_from_info(&info)
    }

    fn normalize_proxy_endpoint(value: &str) -> Option<String> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return None;
        }
        let candidate = if trimmed.contains("://") {
            trimmed.to_owned()
        } else {
            format!("http://{trimmed}")
        };
        let parsed = Url::parse(&candidate).ok()?;
        if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
            return None;
        }
        Some(candidate)
    }

    fn parse_wininet_proxy_server(value: &str) -> (Option<String>, Option<String>) {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return (None, None);
        }
        if !trimmed.contains('=') {
            let endpoint = normalize_proxy_endpoint(trimmed);
            return (endpoint.clone(), endpoint);
        }
        let mut http = None;
        let mut https = None;
        for part in trimmed.split(';') {
            let Some((scheme, endpoint)) = part.split_once('=') else {
                continue;
            };
            match scheme.trim().to_ascii_lowercase().as_str() {
                "http" => http = normalize_proxy_endpoint(endpoint),
                "https" => https = normalize_proxy_endpoint(endpoint),
                _ => {}
            }
        }
        (http, https)
    }

    fn normalize_proxy_override(value: &str) -> String {
        let mut entries = vec![
            "127.0.0.1".to_owned(),
            "localhost".to_owned(),
            "::1".to_owned(),
        ];
        for raw in value.split([';', ',']) {
            let candidate = raw.trim();
            if candidate.is_empty() {
                continue;
            }
            if candidate.eq_ignore_ascii_case("<local>") {
                continue;
            }
            if candidate.starts_with('<') && candidate.ends_with('>') {
                continue;
            }
            if !entries
                .iter()
                .any(|entry| entry.eq_ignore_ascii_case(candidate))
            {
                entries.push(candidate.to_owned());
            }
        }
        entries.join(",")
    }

    fn read_internet_settings() -> Option<(bool, String, String)> {
        let subkey = wide(OsStr::new(
            "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
        ));
        let mut key = std::ptr::null_mut();
        if unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, subkey.as_ptr(), 0, KEY_READ, &mut key) } != 0
        {
            return None;
        }

        let read_dword = |name: &str| -> Option<u32> {
            let name = wide(OsStr::new(name));
            let mut value = 0_u32;
            let mut value_type = 0_u32;
            let mut size = std::mem::size_of::<u32>() as u32;
            let status = unsafe {
                RegQueryValueExW(
                    key,
                    name.as_ptr(),
                    std::ptr::null(),
                    &mut value_type,
                    (&mut value as *mut u32).cast::<u8>(),
                    &mut size,
                )
            };
            (status == 0 && value_type == REG_DWORD && size == 4).then_some(value)
        };

        let read_string = |name: &str| -> Option<String> {
            let name = wide(OsStr::new(name));
            let mut value_type = 0_u32;
            let mut size = 0_u32;
            if unsafe {
                RegQueryValueExW(
                    key,
                    name.as_ptr(),
                    std::ptr::null(),
                    &mut value_type,
                    std::ptr::null_mut(),
                    &mut size,
                )
            } != 0
                || value_type != REG_SZ
                || size < 2
            {
                return None;
            }
            let mut bytes = vec![0_u8; size as usize];
            if unsafe {
                RegQueryValueExW(
                    key,
                    name.as_ptr(),
                    std::ptr::null(),
                    &mut value_type,
                    bytes.as_mut_ptr(),
                    &mut size,
                )
            } != 0
            {
                return None;
            }
            let units: Vec<u16> = bytes[..size as usize]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes(*chunk))
                .take_while(|unit| *unit != 0)
                .collect();
            Some(String::from_utf16_lossy(&units))
        };

        let enabled = read_dword("ProxyEnable").unwrap_or(0) != 0;
        let server = read_string("ProxyServer").unwrap_or_default();
        let override_value = read_string("ProxyOverride").unwrap_or_default();
        unsafe { RegCloseKey(key) };
        Some((enabled, server, override_value))
    }

    fn windows_proxy_environment() -> BTreeMap<String, String> {
        let mut values = BTreeMap::new();
        let Some((enabled, proxy_server, proxy_override)) = read_internet_settings() else {
            return values;
        };
        if !enabled {
            return values;
        }
        let (http, https) = parse_wininet_proxy_server(&proxy_server);
        if let Some(proxy) = http {
            values.insert("HTTP_PROXY".into(), proxy.clone());
            values.insert("http_proxy".into(), proxy);
        }
        if let Some(proxy) = https {
            values.insert("HTTPS_PROXY".into(), proxy.clone());
            values.insert("https_proxy".into(), proxy);
        }
        let no_proxy = normalize_proxy_override(&proxy_override);
        values.insert("NO_PROXY".into(), no_proxy.clone());
        values.insert("no_proxy".into(), no_proxy);
        values
    }

    fn first_env(names: &[&str]) -> Option<String> {
        names.iter().find_map(|name| {
            env::var(name)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        })
    }

    fn resolved_proxy_environment() -> BTreeMap<String, String> {
        let windows = windows_proxy_environment();
        let mut values = BTreeMap::new();

        let product_override =
            first_env(&["OCP_HTTPS_PROXY"]).and_then(|value| normalize_proxy_endpoint(&value));
        let explicit_http = first_env(&["HTTP_PROXY", "http_proxy"])
            .and_then(|value| normalize_proxy_endpoint(&value));
        let explicit_https = first_env(&["HTTPS_PROXY", "https_proxy"])
            .and_then(|value| normalize_proxy_endpoint(&value));

        let http = explicit_http
            .clone()
            .or_else(|| product_override.clone())
            .or_else(|| windows.get("HTTP_PROXY").cloned())
            .or_else(|| explicit_https.clone());
        let https = explicit_https
            .clone()
            .or_else(|| product_override.clone())
            .or_else(|| windows.get("HTTPS_PROXY").cloned())
            .or_else(|| explicit_http.clone());

        if let Some(proxy) = product_override.or_else(|| https.clone()) {
            values.insert("OCP_HTTPS_PROXY".into(), proxy);
        }
        if let Some(proxy) = http {
            values.insert("HTTP_PROXY".into(), proxy.clone());
            values.insert("http_proxy".into(), proxy);
        }
        if let Some(proxy) = https {
            values.insert("HTTPS_PROXY".into(), proxy.clone());
            values.insert("https_proxy".into(), proxy);
        }

        let no_proxy_source = first_env(&["NO_PROXY", "no_proxy"])
            .or_else(|| windows.get("NO_PROXY").cloned())
            .unwrap_or_default();
        let no_proxy = normalize_proxy_override(&no_proxy_source);
        values.insert("NO_PROXY".into(), no_proxy.clone());
        values.insert("no_proxy".into(), no_proxy);
        values
    }

    fn apply_managed_env(command: &mut Command, values: &BTreeMap<String, String>) {
        for name in MANAGED_ENV {
            command.env_remove(name);
        }
        for (name, value) in values {
            command.env(name, value);
        }
    }

    fn spawn_hidden(
        path: &Path,
        args: &[&str],
        cwd: &Path,
        envs: Option<&BTreeMap<String, String>>,
    ) -> io::Result<Child> {
        let mut command = Command::new(path);
        command
            .args(args)
            .current_dir(cwd)
            .creation_flags(CREATE_NO_WINDOW);
        if let Some(values) = envs {
            apply_managed_env(&mut command, values);
        }
        command.spawn()
    }

    fn forward_shell(layout: &Layout, arg: &str) -> Result<(), String> {
        spawn_hidden(&layout.shell, &[arg], &layout.root, None)
            .map(|_| ())
            .map_err(|e| format!("Could not invoke Desktop Shell: {e}"))
    }

    fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if predicate() {
                return true;
            }
            thread::sleep(Duration::from_millis(200));
        }
        predicate()
    }

    fn store_loopback_primary_ready_at(origin: Option<&str>, port: u16) -> bool {
        let Some(origin) = origin else { return false };
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(150))
        else {
            return false;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
        let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
        let request = format!(
            "GET /v1/runtime-state HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: {origin}\r\nConnection: close\r\n\r\n"
        );
        if stream.write_all(request.as_bytes()).is_err() {
            return false;
        }
        let mut response = Vec::with_capacity(1024);
        if stream.read_to_end(&mut response).is_err() {
            return false;
        }
        let text = String::from_utf8_lossy(&response);
        text.starts_with("HTTP/1.1 200") && text.contains("\"ok\":true")
    }

    fn store_loopback_primary_ready(origin: Option<&str>) -> bool {
        store_loopback_primary_ready_at(origin, 47_832)
    }

    fn runtime_single_instance_ready_at(port: u16) -> bool {
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        TcpStream::connect_timeout(&address, Duration::from_millis(150)).is_ok()
    }

    fn runtime_single_instance_ready() -> bool {
        runtime_single_instance_ready_at(47_831)
    }

    fn relay_install_handoff_at(
        origin: &str,
        handoff: &InstallHandoff,
        port: u16,
    ) -> Result<(), String> {
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_millis(500))
            .map_err(|_| "OCP Desktop install bridge is unavailable".to_owned())?;
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        let body = serde_json::json!({
            "packageId": handoff.package_id,
            "version": handoff.version,
            "grant": handoff.grant,
        })
        .to_string();
        let request = format!(
            "POST /v1/install-handoff HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: {origin}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream
            .write_all(request.as_bytes())
            .map_err(|_| "Could not send install handoff to OCP Desktop".to_owned())?;
        let mut response = Vec::with_capacity(1024);
        stream
            .read_to_end(&mut response)
            .map_err(|_| "Could not read install acknowledgement from OCP Desktop".to_owned())?;
        let text = String::from_utf8_lossy(&response);
        if text.starts_with("HTTP/1.1 202") && text.contains("\"ok\":true") {
            Ok(())
        } else {
            Err("OCP Desktop rejected the install handoff".to_owned())
        }
    }

    fn relay_install_handoff(origin: &str, handoff: &InstallHandoff) -> Result<(), String> {
        relay_install_handoff_at(origin, handoff, 47_832)
    }

    fn exit_code(status: ExitStatus) -> i32 {
        status.code().unwrap_or(-1)
    }

    fn prepare_environment(
        layout: &Layout,
        session: &str,
        token: &str,
        store_origin: Option<&str>,
        update_config: Option<&UpdateConfig>,
        runtime_version: Option<&str>,
        paths: &[PathBuf; 5],
    ) -> BTreeMap<String, String> {
        let mut envs = BTreeMap::new();
        envs.insert(
            "OCP_IPC_SOCKET".into(),
            format!("ocp-runtime-{}", &session[..12]),
        );
        envs.insert("OCP_IPC_TOKEN".into(), token.into());
        envs.insert(
            "OCP_NATIVE_HOST_HANDOFF_PATH".into(),
            paths[0].to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_NATIVE_HOST_EVENT_PATH".into(),
            paths[1].to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_NATIVE_HOST_COMMAND_PATH".into(),
            paths[2].to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_NATIVE_HOST_UI_COMMAND_PATH".into(),
            paths[3].to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_NATIVE_HOST_BUBBLE_PATH".into(),
            paths[4].to_string_lossy().into_owned(),
        );
        envs.insert("OCP_NATIVE_HOST_TOKEN".into(), token.into());
        envs.insert("OCP_NATIVE_HOST_EMBED".into(), "1".into());
        envs.insert("OCP_NATIVE_HOST_SIZE".into(), "384".into());
        envs.insert(
            "OCP_NATIVE_HOST_HITBOX".into(),
            "0.08,0.02,0.84,0.96".into(),
        );
        envs.insert("OCP_NATIVE_INTERACTIVE".into(), "1".into());
        envs.insert("OCP_NATIVE_PRODUCTION_ENABLED".into(), "1".into());
        envs.insert("OCP_PRESENTATION_MODE".into(), "native-companion".into());
        envs.insert("OCP_DESKTOP_SHELL_ENABLED".into(), "1".into());
        envs.insert("OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER".into(), "1".into());
        envs.insert(
            "OCP_DESKTOP_SHELL_EXECUTABLE".into(),
            layout.shell.to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_DESKTOP_SHELL_ROOT".into(),
            layout.shell_root.to_string_lossy().into_owned(),
        );
        if let Some(origin) = store_origin {
            envs.insert("OCP_STORE_LOOPBACK_ORIGINS".into(), origin.into());
            envs.insert("OCP_STORE_URL".into(), format!("{origin}/"));
        }
        envs.insert(
            "OCP_UPDATER_EXE".into(),
            layout.updater.to_string_lossy().into_owned(),
        );
        let staging_dir = env::var("OCP_UPDATE_STAGING_DIR")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| layout.update_root.to_string_lossy().into_owned());
        envs.insert("OCP_UPDATE_STAGING_DIR".into(), staging_dir);
        envs.insert(
            "OCP_UPDATE_APPLY_SCRIPT".into(),
            layout.apply_helper.to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_UPDATE_INSTALL_ROOT".into(),
            layout.root.to_string_lossy().into_owned(),
        );
        // The updater accepts either a native EXE or the legacy PowerShell
        // compatibility script. Production restarts must come back through the
        // native launcher so no long-running powershell.exe supervisor returns.
        envs.insert(
            "OCP_UPDATE_START_SCRIPT".into(),
            layout.launcher.to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_UPDATE_STATUS_FILE".into(),
            layout.update_status.to_string_lossy().into_owned(),
        );
        envs.insert(
            "OCP_UPDATE_HEALTH_FILE".into(),
            layout.update_health.to_string_lossy().into_owned(),
        );
        if let Some(update) = update_config {
            if let (Some(manifest), Some(key_id), Some(public_key)) = (
                update.manifest_url.as_ref(),
                update.key_id.as_ref(),
                update.public_key_base64.as_ref(),
            ) {
                envs.insert("OCP_UPDATE_MANIFEST_URL".into(), manifest.clone());
                envs.insert("OCP_UPDATE_KEY_ID".into(), key_id.clone());
                envs.insert("OCP_UPDATE_PUBLIC_KEY_B64".into(), public_key.clone());
            }
            if let (Some(manifest), Some(key_id), Some(public_key)) = (
                update.preview_manifest_url.as_ref(),
                update.preview_key_id.as_ref(),
                update.preview_public_key_base64.as_ref(),
            ) {
                envs.insert("OCP_UPDATE_PREVIEW_MANIFEST_URL".into(), manifest.clone());
                envs.insert("OCP_UPDATE_PREVIEW_KEY_ID".into(), key_id.clone());
                envs.insert(
                    "OCP_UPDATE_PREVIEW_PUBLIC_KEY_B64".into(),
                    public_key.clone(),
                );
            }
            envs.insert(
                "OCP_UPDATE_AUTOMATIC_CHECKS".into(),
                if update.automatic_checks { "1" } else { "0" }.into(),
            );
            envs.insert(
                "OCP_UPDATE_STABLE_TRUST_READY".into(),
                if update.stable_trust_ready { "1" } else { "0" }.into(),
            );
        }
        if let Ok(expected) = env::var("OCP_UPDATE_EXPECTED_VERSION") {
            if !expected.trim().is_empty() {
                envs.insert("OCP_UPDATE_EXPECTED_VERSION".into(), expected);
            }
        }
        if let Some(version) = runtime_version {
            envs.insert("OCP_RUNTIME_VERSION".into(), version.into());
        }
        envs.extend(resolved_proxy_environment());
        envs
    }

    fn shutdown_desktop_shell(layout: &Layout, log: &LauncherLog) {
        if process_ids_by_path(&layout.shell).is_empty() {
            return;
        }
        log.write("[launcher] requesting Desktop Shell shutdown");
        let _ = forward_shell(layout, "--ocp-exit=runtime-owner-shutdown");
        if !wait_until(Duration::from_secs(6), || {
            process_ids_by_path(&layout.shell).is_empty()
        }) {
            log.write("[launcher] Desktop Shell shutdown timeout; applying exact-path fallback");
            terminate_processes_by_path(&layout.shell);
        }
    }

    fn run() -> Result<(), String> {
        let layout = layout()?;
        validate_layout(&layout)?;
        let protocol_uri = parse_protocol_uri()?;
        let open_home = parse_open_home_request();
        let store_origin = load_store_origin(&layout)?;
        let install_handoff = match protocol_uri.as_deref() {
            Some(uri) => parse_install_handoff_uri(uri)?,
            None => None,
        };

        // An install deep link can arrive while a development Runtime (or a Runtime
        // owned by another launcher generation) is already alive. Starting another
        // Runtime only makes the single-instance guard kill the duplicate before
        // Electron receives the grant. Prefer the existing authenticated Desktop
        // Store bridge and do not create a second process tree.
        if let (Some(handoff), Some(origin)) = (install_handoff.as_ref(), store_origin.as_deref()) {
            if store_loopback_primary_ready(Some(origin)) {
                relay_install_handoff(origin, handoff)?;
                return Ok(());
            }
            if runtime_single_instance_ready() {
                let ready = wait_until(Duration::from_secs(20), || {
                    store_loopback_primary_ready(Some(origin))
                });
                if !ready {
                    return Err(
                        "OCP Runtime is already running, but its Desktop install bridge did not become ready within 20 seconds"
                            .to_owned(),
                    );
                }
                relay_install_handoff(origin, handoff)?;
                return Ok(());
            }
        }

        let (_mutex, already_running) = acquire_launcher_mutex()
            .map_err(|e| format!("Cannot acquire OCP launcher lock: {e}"))?;

        if already_running {
            // A second launcher can arrive while the primary is still starting
            // Runtime and before Electron has created its single-instance
            // primary. Wait for the packaged Shell instead of racing it.
            if !wait_until(Duration::from_secs(20), || {
                !process_ids_by_path(&layout.shell).is_empty()
            }) {
                return Err(
                    "OCP is starting, but Desktop Shell did not become ready within 20 seconds"
                        .to_owned(),
                );
            }
            if let Some(uri) = protocol_uri.as_deref() {
                forward_shell(&layout, uri)?;
            } else {
                forward_shell(&layout, "--ocp-open=home")?;
            }
            return Ok(());
        }

        fs::create_dir_all(&layout.log_root)
            .map_err(|e| format!("Cannot create log directory: {e}"))?;
        fs::create_dir_all(&layout.update_root)
            .map_err(|e| format!("Cannot create update directory: {e}"))?;
        fs::create_dir_all(&layout.updater_root)
            .map_err(|e| format!("Cannot create updater directory: {e}"))?;
        fs::copy(&layout.apply_source, &layout.apply_helper)
            .map_err(|e| format!("Cannot stage update helper: {e}"))?;

        let session = Uuid::new_v4().simple().to_string();
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let log = LauncherLog {
            path: layout.log_root.join(format!("launcher-{session}.log")),
        };
        log.write(format!("[launcher] start session={session}"));

        let temp = env::temp_dir();
        let paths = [
            temp.join(format!("ocp-handoff-{session}.json")),
            temp.join(format!("ocp-event-{session}.json")),
            temp.join(format!("ocp-command-{session}.json")),
            temp.join(format!("ocp-ui-command-{session}.json")),
            temp.join(format!("ocp-bubble-{session}.json")),
        ];
        let _temp_guard = TempFiles {
            paths: paths.to_vec(),
        };
        let update_config = load_update_config(&layout)?;
        let runtime_version = load_runtime_version(&layout)?;
        let mut envs = prepare_environment(
            &layout,
            &session,
            &token,
            store_origin.as_deref(),
            update_config.as_ref(),
            runtime_version.as_deref(),
            &paths,
        );

        // A stale packaged Shell from an abnormal previous Runtime termination
        // must not become Electron's single-instance primary for the new bridge.
        terminate_processes_by_path(&layout.shell);

        let mut kernel = spawn_hidden(&layout.kernel, &[], &layout.root, Some(&envs))
            .map_err(|e| format!("Could not start OCP Kernel: {e}"))?;
        let mut native = spawn_hidden(&layout.native, &[], &layout.root, Some(&envs))
            .map_err(|e| format!("Could not start native companion host: {e}"))?;
        envs.insert(
            "OCP_UPDATE_PEER_PROCESS_IDS".into(),
            format!("{},{}", kernel.id(), native.id()),
        );
        let runtime_log = layout.log_root.join(format!("runtime-{session}.log"));
        let runtime_log_arg = runtime_log.to_string_lossy().into_owned();
        let mut runtime = spawn_hidden(
            &layout.runtime,
            &["--log-file", &runtime_log_arg],
            &layout.root,
            Some(&envs),
        )
        .map_err(|e| format!("Could not start OCP Runtime: {e}"))?;

        let result = (|| -> Result<(), String> {
            if protocol_uri.is_some() || open_home {
                // Seeing OCP.exe is not sufficient: Chromium can exist before the
                // Runtime-launched process has acquired Electron's single-instance
                // lock. For protocol handoff, and for normal foreground launches
                // when a Store origin is configured, wait for the authenticated
                // loopback. This also makes the installer's first launch reliably
                // open the Control Center so First Run can render.
                let ready = wait_until(Duration::from_secs(20), || {
                    if runtime.try_wait().ok().flatten().is_some() {
                        return true;
                    }
                    if process_ids_by_path(&layout.shell).is_empty() {
                        return false;
                    }
                    match store_origin.as_deref() {
                        Some(_) => store_loopback_primary_ready(store_origin.as_deref()),
                        None => protocol_uri.is_none(),
                    }
                });
                if runtime.try_wait().map_err(|e| e.to_string())?.is_some() {
                    // The Runtime can legitimately exit here when another Runtime V3
                    // primary owns the single-instance port. This is especially common
                    // when a Store/install handoff arrives while OCP is already open.
                    // Reuse that primary instead of surfacing a false crash dialog.
                    if runtime_single_instance_ready() {
                        log.write("[launcher] spawned Runtime yielded to an existing Runtime V3 primary; reusing existing instance");
                        let existing_ready =
                            wait_until(Duration::from_secs(20), || match store_origin.as_deref() {
                                Some(origin) => store_loopback_primary_ready(Some(origin)),
                                None => !process_ids_by_path(&layout.shell).is_empty(),
                            });
                        if !existing_ready {
                            return Err(
                                "OCP Runtime is already running, but its Desktop Shell bridge did not become ready within 20 seconds"
                                    .to_owned(),
                            );
                        }
                        if let (Some(handoff), Some(origin)) =
                            (install_handoff.as_ref(), store_origin.as_deref())
                        {
                            relay_install_handoff(origin, handoff)?;
                        } else if let Some(uri) = protocol_uri.as_deref() {
                            forward_shell(&layout, uri)?;
                        } else if open_home {
                            forward_shell(&layout, "--ocp-open=home")?;
                        }
                        return Ok(());
                    }
                    return Err(format!(
                        "OCP Runtime exited before Desktop Shell handoff. See {}",
                        runtime_log.display()
                    ));
                }
                if !ready {
                    return Err(
                        "OCP Desktop Shell primary did not become ready within 20 seconds"
                            .to_owned(),
                    );
                }
                if protocol_uri.is_some() && !store_loopback_primary_ready(store_origin.as_deref())
                {
                    return Err("OCP Desktop Shell primary did not expose the authenticated Store loopback within 20 seconds".to_owned());
                }
                if let Some(uri) = protocol_uri.as_deref() {
                    forward_shell(&layout, uri)?;
                } else {
                    forward_shell(&layout, "--ocp-open=home")?;
                    log.write("[launcher] foreground launch opened OCP Control Center");
                }
            }

            loop {
                if let Some(status) = native
                    .try_wait()
                    .map_err(|e| format!("Native host wait failed: {e}"))?
                {
                    if !status.success() {
                        return Err(format!(
                            "OCP native host exited with code {}",
                            exit_code(status)
                        ));
                    }
                    break;
                }
                if let Some(status) = runtime
                    .try_wait()
                    .map_err(|e| format!("Runtime wait failed: {e}"))?
                {
                    return Err(format!(
                        "OCP Runtime exited with code {}. See {}",
                        exit_code(status),
                        runtime_log.display()
                    ));
                }
                thread::sleep(Duration::from_millis(250));
            }

            let runtime_clean = wait_until(Duration::from_secs(8), || {
                runtime.try_wait().ok().flatten().is_some()
            });
            if runtime_clean {
                if let Some(status) = runtime
                    .try_wait()
                    .map_err(|e| format!("Runtime wait failed: {e}"))?
                {
                    if !status.success() {
                        return Err(format!(
                            "OCP Runtime exited with code {}. See {}",
                            exit_code(status),
                            runtime_log.display()
                        ));
                    }
                }
            } else {
                log.write("[launcher] Runtime graceful shutdown exceeded 8 seconds; cleanup fallback will run");
            }

            shutdown_desktop_shell(&layout, &log);
            Ok(())
        })();

        for child in [&mut runtime, &mut native, &mut kernel] {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        log.write(format!("[launcher] exit ok={}", result.is_ok()));
        result
    }

    #[cfg(test)]
    mod tests {
        use super::{
            normalize_proxy_override, parse_build_info, parse_install_handoff_uri,
            parse_wininet_proxy_server, relay_install_handoff_at, runtime_version_from_info,
            store_loopback_primary_ready_at, update_config_from_info, InstallHandoff,
        };
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::thread;

        fn serve_loopback_once(expected_origin: &'static str) -> u16 {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind test loopback");
            let port = listener.local_addr().expect("test loopback addr").port();
            thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("accept test loopback");
                let mut buffer = [0u8; 2048];
                let count = stream.read(&mut buffer).expect("read readiness request");
                let request = String::from_utf8_lossy(&buffer[..count]);
                let allowed = request.contains(&format!("Origin: {expected_origin}"));
                let (status, body) = if allowed {
                    ("200 OK", "{\"ok\":true,\"runtimeAvailable\":true}")
                } else {
                    ("403 Forbidden", "{\"ok\":false}")
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream
                    .write_all(response.as_bytes())
                    .expect("write readiness response");
            });
            port
        }

        fn serve_install_handoff_once(expected_origin: &'static str) -> u16 {
            let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind install loopback");
            let port = listener.local_addr().expect("install loopback addr").port();
            thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("accept install handoff");
                let mut buffer = [0u8; 4096];
                let count = stream.read(&mut buffer).expect("read install handoff");
                let request = String::from_utf8_lossy(&buffer[..count]);
                assert!(request.starts_with("POST /v1/install-handoff HTTP/1.1"));
                assert!(request.contains(&format!("Origin: {expected_origin}")));
                assert!(request.contains("\"packageId\":\"character.sabai-sompoo\""));
                assert!(request.contains("\"version\":\"1.0.1\""));
                assert!(request.contains("\"grant\":"));
                let body = "{\"ok\":true}";
                let response = format!(
                    "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream
                    .write_all(response.as_bytes())
                    .expect("write install acknowledgement");
            });
            port
        }

        #[test]
        fn install_protocol_is_strict_and_projects_handoff() {
            let grant = "A".repeat(43);
            let uri = format!("ocp://install/character.sabai-sompoo?version=1.0.1&grant={grant}");
            let handoff = parse_install_handoff_uri(&uri)
                .expect("valid install URI")
                .expect("install handoff");
            assert_eq!(handoff.package_id, "character.sabai-sompoo");
            assert_eq!(handoff.version, "1.0.1");
            assert_eq!(handoff.grant, grant);
            assert!(
                parse_install_handoff_uri("ocp://install/bad?version=1.0.1&grant=short").is_err()
            );
            assert!(
                parse_install_handoff_uri("ocp://store/character.sabai-sompoo?version=1.0.1")
                    .expect("non-install URI")
                    .is_none()
            );
        }

        #[test]
        fn existing_desktop_install_bridge_accepts_native_launcher_handoff() {
            let port = serve_install_handoff_once("https://ocp.example");
            let handoff = InstallHandoff {
                package_id: "character.sabai-sompoo".to_owned(),
                version: "1.0.1".to_owned(),
                grant: "B".repeat(43),
            };
            relay_install_handoff_at("https://ocp.example", &handoff, port)
                .expect("existing Desktop bridge should accept install handoff");
        }

        #[test]
        fn store_loopback_readiness_requires_exact_origin_and_ok_response() {
            let port = serve_loopback_once("https://ocp.example");
            assert!(store_loopback_primary_ready_at(
                Some("https://ocp.example"),
                port
            ));

            let port = serve_loopback_once("https://ocp.example");
            assert!(!store_loopback_primary_ready_at(
                Some("https://wrong.example"),
                port
            ));
            assert!(!store_loopback_primary_ready_at(None, port));
        }

        #[test]
        fn wininet_proxy_parser_supports_generic_and_protocol_specific_values() {
            let (http, https) = parse_wininet_proxy_server("proxy.toshiba.co.jp:8080");
            assert_eq!(http.as_deref(), Some("http://proxy.toshiba.co.jp:8080"));
            assert_eq!(https.as_deref(), Some("http://proxy.toshiba.co.jp:8080"));

            let (http, https) =
                parse_wininet_proxy_server("http=proxy-http:8080;https=proxy-secure:8443");
            assert_eq!(http.as_deref(), Some("http://proxy-http:8080"));
            assert_eq!(https.as_deref(), Some("http://proxy-secure:8443"));
        }

        #[test]
        fn wininet_proxy_override_always_preserves_local_runtime_addresses() {
            let value = normalize_proxy_override("<local>;*.toshiba.co.jp;10.*");
            assert!(value.contains("127.0.0.1"));
            assert!(value.contains("localhost"));
            assert!(value.contains("::1"));
            assert!(value.contains("*.toshiba.co.jp"));
            assert!(value.contains("10.*"));
            assert!(!value.contains("<local>"));
        }

        #[test]
        fn build_info_accepts_utf8_bom() {
            let info = parse_build_info("\u{feff}{\"storeOrigin\":\"https://ocp.example\"}")
                .expect("BOM-prefixed BUILD-INFO should parse");
            assert_eq!(info.store_origin.as_deref(), Some("https://ocp.example"));
        }

        #[test]
        fn build_info_accepts_plain_json() {
            let info = parse_build_info("{\"storeOrigin\":\"https://ocp.example\"}")
                .expect("plain BUILD-INFO should parse");
            assert_eq!(info.store_origin.as_deref(), Some("https://ocp.example"));
        }

        #[test]
        fn build_info_still_rejects_malformed_json() {
            assert!(parse_build_info("\u{feff}{not-json}").is_err());
        }

        #[test]
        fn build_info_runtime_version_requires_semver() {
            let info = parse_build_info("{\"version\":\"0.1.0-local.28\"}")
                .expect("runtime version BUILD-INFO should parse");
            assert_eq!(
                runtime_version_from_info(&info).expect("valid runtime version"),
                Some("0.1.0-local.28".to_owned())
            );

            let invalid = parse_build_info("{\"version\":\"release 28\"}")
                .expect("invalid version should still parse structurally");
            assert!(runtime_version_from_info(&invalid).is_err());
        }

        #[test]
        fn update_config_requires_complete_pinned_https_metadata() {
            let info = parse_build_info(
                "{\"storeOrigin\":\"https://ocp.example\",\"updateManifestUrl\":\"https://github.com/opencompanionplatform/ocp-releases/releases/latest/download/update-manifest.json\",\"updateKeyId\":\"ed25519:release-1\",\"updatePublicKeyBase64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"automaticUpdateChecks\":true,\"stableUpdateTrustReady\":true}",
            )
            .expect("configured BUILD-INFO should parse");
            let update = update_config_from_info(&info)
                .expect("update config should validate")
                .expect("update config should exist");
            assert_eq!(update.key_id.as_deref(), Some("ed25519:release-1"));
            assert!(update
                .manifest_url
                .as_deref()
                .unwrap_or_default()
                .starts_with("https://github.com/"));
            assert!(update.automatic_checks);
            assert!(update.stable_trust_ready);
            assert!(update.preview_manifest_url.is_none());

            let preview = parse_build_info(
                "{\"updatePreviewManifestUrl\":\"https://github.com/opencompanionplatform/ocp-releases/releases/download/v0.2.0-preview/update-manifest.json\",\"updatePreviewKeyId\":\"ed25519:preview-1\",\"updatePreviewPublicKeyBase64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"automaticUpdateChecks\":true}",
            )
            .expect("preview BUILD-INFO should parse");
            let preview_update = update_config_from_info(&preview)
                .expect("preview update config should validate")
                .expect("preview update config should exist");
            assert!(preview_update.manifest_url.is_none());
            assert_eq!(
                preview_update.preview_key_id.as_deref(),
                Some("ed25519:preview-1")
            );
            assert!(!preview_update.stable_trust_ready);

            let partial = parse_build_info(
                "{\"updateManifestUrl\":\"https://updates.example/manifest.json\",\"automaticUpdateChecks\":true}",
            )
            .expect("partial JSON should parse structurally");
            assert!(update_config_from_info(&partial).is_err());

            let partial_preview = parse_build_info(
                "{\"updatePreviewManifestUrl\":\"https://updates.example/preview.json\",\"automaticUpdateChecks\":true}",
            )
            .expect("partial preview JSON should parse structurally");
            assert!(update_config_from_info(&partial_preview).is_err());

            let unpinned_auto = parse_build_info("{\"automaticUpdateChecks\":true}")
                .expect("automatic-only JSON should parse structurally");
            assert!(update_config_from_info(&unpinned_auto).is_err());
        }
    }

    pub fn main() {
        if let Err(error) = run() {
            if let Ok(layout) = layout() {
                let _ = fs::create_dir_all(&layout.log_root);
                let fallback = LauncherLog {
                    path: layout.log_root.join("launcher-fatal.log"),
                };
                fallback.write(format!("[launcher] fatal: {error}"));
            }
            show_error(&error);
        }
    }
}

#[cfg(windows)]
fn main() {
    windows_launcher::main();
}
