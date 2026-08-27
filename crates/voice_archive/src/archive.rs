use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    fs::{self, File},
    io::{BufReader, Read},
    path::Path,
};

use serde::Deserialize;
use sha2::{Digest, Sha256};

const MANIFEST_FILE: &str = "manifest.json";
const CHECKSUM_FILE: &str = "checksums.json";
const AUDIO_FILE: &str = "audio.caf";

/// Resource limits applied before an archive is accepted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HistoryArchiveLimits {
    /// Maximum readable manifest size.
    pub maximum_manifest_bytes: u64,
    /// Maximum readable checksum-file size.
    pub maximum_checksum_bytes: u64,
    /// Maximum optional audio-artifact size.
    pub maximum_audio_bytes: u64,
    /// Maximum immutable History result count.
    pub maximum_result_count: u32,
}

impl Default for HistoryArchiveLimits {
    fn default() -> Self {
        Self {
            maximum_manifest_bytes: 16 * 1_024 * 1_024,
            maximum_checksum_bytes: 256 * 1_024,
            maximum_audio_bytes: 2 * 1_024 * 1_024 * 1_024,
            maximum_result_count: 10_000,
        }
    }
}

/// Metadata returned only after the complete archive passes validation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedHistoryArchive {
    /// Session UUID bytes in network order.
    pub session_id: [u8; 16],
    /// Number of immutable History results.
    pub result_count: u32,
    /// Whether the archive contains a verified audio artifact.
    pub has_audio: bool,
    /// Total verified manifest and optional audio bytes.
    pub verified_bytes: u64,
    /// SHA-256 of the exact manifest bytes.
    pub manifest_sha256: [u8; 32],
}

/// A validation failure that must prevent archive restore.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HistoryArchiveError {
    /// Archive root is absent, linked, or not a directory.
    InvalidRoot,
    /// Required files or the exact inventory are invalid.
    InvalidInventory,
    /// Manifest or checksum JSON is malformed.
    InvalidManifest,
    /// Archive schema revision is unsupported.
    UnsupportedSchema,
    /// A configured resource limit is invalid or exceeded.
    LimitExceeded,
    /// A declared digest is malformed or does not match.
    IntegrityMismatch,
    /// A session or result identifier is invalid or contradictory.
    InvalidIdentity,
    /// Archive bytes could not be read completely.
    Io,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest {
    #[serde(rename = "format")]
    archive_format: String,
    schema_revision: u32,
    exported_at: String,
    document: Document,
    results: Vec<HistoryResult>,
    audio_filename: Option<String>,
    audio_duration_milliseconds: Option<i64>,
    audio_expired_at: Option<String>,
    audio_expiration_reason: Option<String>,
    recovery_kind: Option<String>,
    recovered_at: Option<String>,
    is_pinned: bool,
}

#[derive(Debug, Deserialize)]
struct Document {
    id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryResult {
    id: String,
    #[serde(rename = "sessionID")]
    session_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Checksums {
    schema_revision: u32,
    algorithm: String,
    files: BTreeMap<String, String>,
}

/// Verifies one immutable Voice History archive without extracting or retaining it.
///
/// # Errors
///
/// Returns a typed failure for malformed roots, contracts, identities, limits,
/// inventory, integrity, or unreadable bytes.
pub fn validate_history_archive(
    root: &Path,
    limits: HistoryArchiveLimits,
) -> Result<ValidatedHistoryArchive, HistoryArchiveError> {
    validate_limits(limits)?;
    let has_audio = verify_inventory(root)?;
    let manifest_bytes = read_bounded(&root.join(MANIFEST_FILE), limits.maximum_manifest_bytes)?;
    let checksum_bytes = read_bounded(&root.join(CHECKSUM_FILE), limits.maximum_checksum_bytes)?;
    let manifest: Manifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| HistoryArchiveError::InvalidManifest)?;
    let checksums: Checksums = serde_json::from_slice(&checksum_bytes)
        .map_err(|_| HistoryArchiveError::InvalidManifest)?;
    validate_contract(
        &manifest,
        &checksums,
        has_audio,
        limits.maximum_result_count,
    )?;

    let manifest_digest = sha256_bytes(&manifest_bytes);
    guard_digest(checksums.files.get(MANIFEST_FILE), &manifest_digest)?;
    let audio_bytes = if has_audio {
        let audio = root.join(AUDIO_FILE);
        let size = regular_file_size(&audio)?;
        if size > limits.maximum_audio_bytes {
            return Err(HistoryArchiveError::LimitExceeded);
        }
        let digest = sha256_file(&audio)?;
        guard_digest(checksums.files.get(AUDIO_FILE), &digest)?;
        size
    } else {
        0
    };
    let verified_bytes = u64::try_from(manifest_bytes.len())
        .map_err(|_| HistoryArchiveError::LimitExceeded)?
        .checked_add(audio_bytes)
        .ok_or(HistoryArchiveError::LimitExceeded)?;
    Ok(ValidatedHistoryArchive {
        session_id: parse_uuid(&manifest.document.id)?,
        result_count: u32::try_from(manifest.results.len())
            .map_err(|_| HistoryArchiveError::LimitExceeded)?,
        has_audio,
        verified_bytes,
        manifest_sha256: manifest_digest,
    })
}

fn validate_limits(limits: HistoryArchiveLimits) -> Result<(), HistoryArchiveError> {
    if limits.maximum_manifest_bytes == 0
        || limits.maximum_checksum_bytes == 0
        || limits.maximum_result_count == 0
    {
        return Err(HistoryArchiveError::LimitExceeded);
    }
    Ok(())
}

fn verify_inventory(root: &Path) -> Result<bool, HistoryArchiveError> {
    let metadata = fs::symlink_metadata(root).map_err(|_| HistoryArchiveError::InvalidRoot)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(HistoryArchiveError::InvalidRoot);
    }
    let mut names = BTreeSet::new();
    for entry in fs::read_dir(root).map_err(|_| HistoryArchiveError::Io)? {
        let entry = entry.map_err(|_| HistoryArchiveError::Io)?;
        let file_type = entry.file_type().map_err(|_| HistoryArchiveError::Io)?;
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            return Err(HistoryArchiveError::InvalidInventory);
        };
        if file_type.is_symlink()
            || !file_type.is_file()
            || !matches!(name.as_str(), MANIFEST_FILE | CHECKSUM_FILE | AUDIO_FILE)
            || !names.insert(name)
        {
            return Err(HistoryArchiveError::InvalidInventory);
        }
    }
    if !names.contains(MANIFEST_FILE) || !names.contains(CHECKSUM_FILE) {
        return Err(HistoryArchiveError::InvalidInventory);
    }
    Ok(names.contains(AUDIO_FILE))
}

fn validate_contract(
    manifest: &Manifest,
    checksums: &Checksums,
    has_audio: bool,
    maximum_result_count: u32,
) -> Result<(), HistoryArchiveError> {
    if manifest.archive_format != "voice_history"
        || manifest.schema_revision != 1
        || checksums.schema_revision != 1
    {
        return Err(HistoryArchiveError::UnsupportedSchema);
    }
    if checksums.algorithm != "SHA-256"
        || manifest.exported_at.is_empty()
        || manifest.results.is_empty()
        || manifest.results.len()
            > usize::try_from(maximum_result_count)
                .map_err(|_| HistoryArchiveError::LimitExceeded)?
        || (manifest.audio_filename.as_deref() == Some(AUDIO_FILE)) != has_audio
        || manifest
            .audio_filename
            .as_deref()
            .is_some_and(|name| name != AUDIO_FILE)
        || has_audio && manifest.audio_duration_milliseconds.is_none()
        || manifest
            .audio_duration_milliseconds
            .is_some_and(|value| value <= 0)
        || manifest.audio_expired_at.is_some() != manifest.audio_expiration_reason.is_some()
        || has_audio && manifest.audio_expired_at.is_some()
        || manifest.recovery_kind.is_some() != manifest.recovered_at.is_some()
    {
        return Err(HistoryArchiveError::InvalidManifest);
    }
    let expected_files: BTreeSet<_> = if has_audio {
        [MANIFEST_FILE.to_owned(), AUDIO_FILE.to_owned()]
            .into_iter()
            .collect()
    } else {
        [MANIFEST_FILE.to_owned()].into_iter().collect()
    };
    if checksums.files.keys().cloned().collect::<BTreeSet<_>>() != expected_files
        || checksums
            .files
            .values()
            .any(|digest| !is_lowercase_sha256(digest))
    {
        return Err(HistoryArchiveError::InvalidManifest);
    }
    let session_id = parse_uuid(&manifest.document.id)?;
    let mut result_ids = BTreeSet::new();
    for result in &manifest.results {
        if parse_uuid(&result.session_id)? != session_id
            || !result_ids.insert(parse_uuid(&result.id)?)
        {
            return Err(HistoryArchiveError::InvalidIdentity);
        }
    }
    let _ = manifest.is_pinned;
    Ok(())
}

fn read_bounded(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>, HistoryArchiveError> {
    if regular_file_size(path)? > maximum_bytes {
        return Err(HistoryArchiveError::LimitExceeded);
    }
    let file = File::open(path).map_err(|_| HistoryArchiveError::Io)?;
    let mut bytes = Vec::new();
    file.take(maximum_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| HistoryArchiveError::Io)?;
    if u64::try_from(bytes.len()).map_err(|_| HistoryArchiveError::LimitExceeded)? > maximum_bytes {
        return Err(HistoryArchiveError::LimitExceeded);
    }
    Ok(bytes)
}

fn regular_file_size(path: &Path) -> Result<u64, HistoryArchiveError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| HistoryArchiveError::InvalidInventory)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(HistoryArchiveError::InvalidInventory);
    }
    Ok(metadata.len())
}

fn guard_digest(expected: Option<&String>, actual: &[u8; 32]) -> Result<(), HistoryArchiveError> {
    let Some(expected) = expected else {
        return Err(HistoryArchiveError::InvalidManifest);
    };
    if decode_sha256(expected).as_ref() != Some(actual) {
        return Err(HistoryArchiveError::IntegrityMismatch);
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<[u8; 32], HistoryArchiveError> {
    let file = File::open(path).map_err(|_| HistoryArchiveError::Io)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8 * 1_024];
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|_| HistoryArchiveError::Io)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(finalize_sha256(hasher))
}

fn sha256_bytes(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    finalize_sha256(hasher)
}

fn finalize_sha256(hasher: Sha256) -> [u8; 32] {
    let mut result = [0_u8; 32];
    result.copy_from_slice(&hasher.finalize());
    result
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn decode_sha256(value: &str) -> Option<[u8; 32]> {
    if !is_lowercase_sha256(value) {
        return None;
    }
    let mut output = [0_u8; 32];
    for (index, pair) in value.as_bytes().as_chunks::<2>().0.iter().enumerate() {
        output[index] = hex_value(pair[0])? * 16 + hex_value(pair[1])?;
    }
    Some(output)
}

fn parse_uuid(value: &str) -> Result<[u8; 16], HistoryArchiveError> {
    if value.len() != 36
        || value.as_bytes().get(8) != Some(&b'-')
        || value.as_bytes().get(13) != Some(&b'-')
        || value.as_bytes().get(18) != Some(&b'-')
        || value.as_bytes().get(23) != Some(&b'-')
    {
        return Err(HistoryArchiveError::InvalidIdentity);
    }
    let compact: Vec<_> = value.bytes().filter(|byte| *byte != b'-').collect();
    if compact.len() != 32 {
        return Err(HistoryArchiveError::InvalidIdentity);
    }
    let mut output = [0_u8; 16];
    for (index, pair) in compact.as_slice().as_chunks::<2>().0.iter().enumerate() {
        output[index] = hex_value(pair[0])
            .and_then(|high| hex_value(pair[1]).map(|low| high * 16 + low))
            .ok_or(HistoryArchiveError::InvalidIdentity)?;
    }
    Ok(output)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

impl fmt::Display for HistoryArchiveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for HistoryArchiveError {}
