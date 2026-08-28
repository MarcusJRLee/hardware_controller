use std::{collections::BTreeSet, fmt, path::Path};

use serde::Deserialize;

use crate::model_package_file_system::{
    declared_directories, is_lowercase_sha256, read_manifest, sha256_bytes, validate_relative_path,
    verify_file, verify_inventory,
};

const MAXIMUM_LANGUAGE_COUNT: usize = 256;

/// Resource limits applied before a package is accepted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ModelPackageLimits {
    /// Maximum readable manifest size.
    pub maximum_manifest_bytes: u64,
    /// Maximum sum of declared payload bytes.
    pub maximum_installed_bytes: u64,
    /// Maximum number of declared payload files.
    pub maximum_file_count: u32,
}

impl Default for ModelPackageLimits {
    fn default() -> Self {
        Self {
            maximum_manifest_bytes: 1_048_576,
            maximum_installed_bytes: 8 * 1_024 * 1_024 * 1_024,
            maximum_file_count: 4_096,
        }
    }
}

/// Runtime family required by a package.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ModelRuntime {
    /// Portable sherpa-onnx runtime.
    SherpaOnnx,
    /// Portable whisper.cpp runtime.
    WhisperCpp,
    /// Rust-native mistral.rs runtime.
    MistralRs,
    /// Portable llama.cpp runtime.
    LlamaCpp,
}

/// One inference stage implemented by a package.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ModelStage {
    /// Audio-to-text recognition.
    Asr,
    /// Text-only formatting.
    Formatting,
    /// Voice activity detection.
    Vad,
}

/// One portable model capability.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd)]
#[serde(rename_all = "snake_case")]
pub enum ModelCapability {
    /// Incremental audio recognition.
    StreamingAsr,
    /// Completed-file recognition.
    FileAsr,
    /// Text-only formatting.
    Formatting,
    /// Voice activity detection.
    Vad,
}

/// Verified package license metadata.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelLicense {
    /// SPDX license expression supplied by the publisher.
    pub spdx_expression: String,
    /// Declared in-package notice path.
    pub notice_file: String,
    /// Publisher or upstream source URL.
    pub source_url: String,
}

/// Declared resource requirements.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ModelResources {
    /// Minimum working memory claimed by the package.
    pub minimum_memory_bytes: u64,
    /// Recommended working memory claimed by the package.
    pub recommended_memory_bytes: u64,
}

/// Identity and capabilities returned only after complete verification.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedModelPackage {
    /// Stable reverse-domain package identifier.
    pub package_id: String,
    /// Publisher-controlled package version.
    pub version: String,
    /// User-visible package name.
    pub display_name: String,
    /// Runtime family required by the package.
    pub runtime: ModelRuntime,
    /// Inference stage implemented by the package.
    pub stage: ModelStage,
    /// Verified capabilities in manifest order.
    pub capabilities: Vec<ModelCapability>,
    /// Declared BCP-47-like language tags.
    pub languages: Vec<String>,
    /// Verified license metadata.
    pub license: ModelLicense,
    /// Declared memory requirements.
    pub resources: ModelResources,
    /// Verified payload files in manifest order.
    pub files: Vec<ValidatedModelFile>,
    /// Number of verified payload files.
    pub file_count: u32,
    /// Sum of verified payload bytes.
    pub verified_bytes: u64,
    /// SHA-256 of the exact manifest bytes.
    pub manifest_sha256: [u8; 32],
}

/// One digest-verified file belonging to a validated Model package.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedModelFile {
    /// Canonical package-relative path.
    pub path: String,
    /// Semantic role used by runtime adapters.
    pub role: ModelFileRole,
    /// Verified byte count.
    pub bytes: u64,
    /// Verified lowercase SHA-256 text from the manifest.
    pub sha256: String,
}

/// A package validation failure that must prevent installation or inference.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelPackageError {
    /// Package root is absent, linked, or not a directory.
    InvalidPackageRoot,
    /// Manifest is absent, linked, or not a regular file.
    InvalidManifestFile,
    /// Manifest exceeds its configured byte limit.
    ManifestBytesExceeded,
    /// Manifest JSON or a typed field is invalid.
    InvalidManifest,
    /// Exact manifest bytes do not match an expected catalog digest.
    ManifestDigestMismatch,
    /// Manifest schema revision is not supported.
    UnsupportedSchemaVersion,
    /// Package identifier is not canonical.
    InvalidPackageId,
    /// Package version is empty or contains unsafe characters.
    InvalidVersion,
    /// Display name is empty or contains control characters.
    InvalidDisplayName,
    /// SPDX expression or source URL is invalid.
    InvalidLicense,
    /// Memory metadata is inconsistent.
    InvalidResources,
    /// A language tag is malformed.
    InvalidLanguage,
    /// A language tag is repeated.
    DuplicateLanguage,
    /// A capability is repeated.
    DuplicateCapability,
    /// Capabilities do not belong to the declared stage.
    CapabilityStageMismatch,
    /// The declared stage has no usable capability.
    MissingCapability,
    /// Declared file count exceeds its configured limit.
    FileCountExceeded,
    /// Declared payload bytes exceed their configured limit or overflow.
    InstalledBytesExceeded,
    /// A package-relative path is not canonical.
    InvalidFilePath {
        /// Invalid manifest path.
        path: String,
    },
    /// A file path is declared more than once.
    DuplicateFilePath {
        /// Repeated manifest path.
        path: String,
    },
    /// A digest is not 64 lowercase hexadecimal characters.
    InvalidDigest {
        /// File carrying the malformed digest.
        path: String,
    },
    /// A declared payload is empty.
    InvalidFileSize {
        /// Empty package-relative path.
        path: String,
    },
    /// No model payload is declared.
    MissingModelFile,
    /// The license notice is absent or has the wrong role.
    MissingNoticeFile,
    /// Symbolic links are not accepted anywhere in a package.
    SymbolicLink {
        /// Linked package-relative path.
        path: String,
    },
    /// A regular payload was not declared by the manifest.
    UndeclaredFile {
        /// Undeclared package-relative path.
        path: String,
    },
    /// A directory is not an ancestor of any declared payload.
    UndeclaredDirectory {
        /// Undeclared package-relative path.
        path: String,
    },
    /// A declared payload is absent or not a regular file.
    MissingFile {
        /// Missing package-relative path.
        path: String,
    },
    /// Actual file bytes do not match the manifest.
    FileSizeMismatch {
        /// Mismatched package-relative path.
        path: String,
    },
    /// Actual SHA-256 does not match the manifest.
    DigestMismatch {
        /// Mismatched package-relative path.
        path: String,
    },
    /// The package could not be read completely.
    Io,
}

impl fmt::Display for ModelPackageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "model package validation failed: {self:?}")
    }
}

impl std::error::Error for ModelPackageError {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    package_id: String,
    version: String,
    display_name: String,
    runtime: ModelRuntime,
    stage: ModelStage,
    capabilities: Vec<ModelCapability>,
    languages: Vec<String>,
    license: ManifestLicense,
    resources: ManifestResources,
    files: Vec<ManifestFile>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestLicense {
    spdx_expression: String,
    notice_file: String,
    source_url: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestResources {
    minimum_memory_bytes: u64,
    recommended_memory_bytes: u64,
}

/// Semantic purpose of one verified package file.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ModelFileRole {
    /// Primary inference weights or graph.
    Model,
    /// Runtime tokenizer data.
    Tokenizer,
    /// Runtime configuration data.
    Configuration,
    /// Runtime vocabulary data.
    Vocabulary,
    /// Human-readable license notice.
    Notice,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ManifestFile {
    pub(crate) path: String,
    role: ModelFileRole,
    pub(crate) bytes: u64,
    pub(crate) sha256: String,
}

/// Verifies a local package without following links or retaining file handles.
///
/// The caller must keep the package staging directory private from concurrent
/// mutation until installation completes.
///
/// # Errors
///
/// Returns a typed failure when the root, manifest, metadata, inventory, size,
/// or digest violates the package contract or cannot be read completely.
pub fn validate_model_package(
    root: &Path,
    limits: ModelPackageLimits,
    expected_manifest_sha256: Option<[u8; 32]>,
) -> Result<ValidatedModelPackage, ModelPackageError> {
    let manifest_bytes = read_manifest(root, limits.maximum_manifest_bytes)?;
    let manifest_sha256 = sha256_bytes(&manifest_bytes);
    if expected_manifest_sha256.is_some_and(|expected| expected != manifest_sha256) {
        return Err(ModelPackageError::ManifestDigestMismatch);
    }
    let manifest: Manifest =
        serde_json::from_slice(&manifest_bytes).map_err(|_| ModelPackageError::InvalidManifest)?;

    validate_manifest(root, manifest, manifest_sha256, limits)
}

fn validate_manifest(
    root: &Path,
    manifest: Manifest,
    manifest_sha256: [u8; 32],
    limits: ModelPackageLimits,
) -> Result<ValidatedModelPackage, ModelPackageError> {
    if manifest.schema_version != 1 {
        return Err(ModelPackageError::UnsupportedSchemaVersion);
    }
    validate_identity(&manifest)?;
    validate_capabilities(manifest.stage, &manifest.capabilities)?;
    validate_languages(manifest.stage, &manifest.languages)?;
    validate_license(&manifest.license)?;
    validate_resources(&manifest.resources)?;

    let maximum_file_count = usize::try_from(limits.maximum_file_count)
        .map_err(|_| ModelPackageError::FileCountExceeded)?;
    if manifest.files.len() > maximum_file_count {
        return Err(ModelPackageError::FileCountExceeded);
    }

    let mut declared_paths = BTreeSet::new();
    let mut installed_bytes = 0_u64;
    let mut has_model = false;
    let mut has_notice = false;
    for file in &manifest.files {
        validate_relative_path(&file.path)?;
        if !declared_paths.insert(file.path.clone()) {
            return Err(ModelPackageError::DuplicateFilePath {
                path: file.path.clone(),
            });
        }
        if !is_lowercase_sha256(&file.sha256) {
            return Err(ModelPackageError::InvalidDigest {
                path: file.path.clone(),
            });
        }
        if file.bytes == 0 {
            return Err(ModelPackageError::InvalidFileSize {
                path: file.path.clone(),
            });
        }
        installed_bytes = installed_bytes
            .checked_add(file.bytes)
            .ok_or(ModelPackageError::InstalledBytesExceeded)?;
        if installed_bytes > limits.maximum_installed_bytes {
            return Err(ModelPackageError::InstalledBytesExceeded);
        }
        has_model |= file.role == ModelFileRole::Model;
        has_notice |=
            file.role == ModelFileRole::Notice && file.path == manifest.license.notice_file;
    }
    if !has_model {
        return Err(ModelPackageError::MissingModelFile);
    }
    if !has_notice {
        return Err(ModelPackageError::MissingNoticeFile);
    }

    let declared_directories = declared_directories(&declared_paths);
    verify_inventory(root, &declared_paths, &declared_directories)?;
    for file in &manifest.files {
        verify_file(root, file)?;
    }

    let file_count =
        u32::try_from(manifest.files.len()).map_err(|_| ModelPackageError::FileCountExceeded)?;
    Ok(ValidatedModelPackage {
        package_id: manifest.package_id,
        version: manifest.version,
        display_name: manifest.display_name,
        runtime: manifest.runtime,
        stage: manifest.stage,
        capabilities: manifest.capabilities,
        languages: manifest.languages,
        license: ModelLicense {
            spdx_expression: manifest.license.spdx_expression,
            notice_file: manifest.license.notice_file,
            source_url: manifest.license.source_url,
        },
        resources: ModelResources {
            minimum_memory_bytes: manifest.resources.minimum_memory_bytes,
            recommended_memory_bytes: manifest.resources.recommended_memory_bytes,
        },
        files: manifest
            .files
            .into_iter()
            .map(|file| ValidatedModelFile {
                path: file.path,
                role: file.role,
                bytes: file.bytes,
                sha256: file.sha256,
            })
            .collect(),
        file_count,
        verified_bytes: installed_bytes,
        manifest_sha256,
    })
}

fn validate_identity(manifest: &Manifest) -> Result<(), ModelPackageError> {
    let package_id = manifest.package_id.as_bytes();
    if package_id.is_empty()
        || package_id.len() > 128
        || manifest.package_id.contains("..")
        || !manifest.package_id.contains('.')
        || !package_id.iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_')
        })
        || !package_id[0].is_ascii_lowercase()
        || manifest.package_id.split('.').any(|segment| {
            segment.is_empty()
                || !segment
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_lowercase)
        })
    {
        return Err(ModelPackageError::InvalidPackageId);
    }
    if !valid_token(&manifest.version, 64) {
        return Err(ModelPackageError::InvalidVersion);
    }
    if manifest.display_name.trim().is_empty()
        || manifest.display_name.len() > 128
        || manifest.display_name.chars().any(char::is_control)
    {
        return Err(ModelPackageError::InvalidDisplayName);
    }
    Ok(())
}

fn valid_token(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
}

fn validate_capabilities(
    stage: ModelStage,
    capabilities: &[ModelCapability],
) -> Result<(), ModelPackageError> {
    if capabilities.is_empty() {
        return Err(ModelPackageError::MissingCapability);
    }
    let mut unique = BTreeSet::new();
    for capability in capabilities {
        if !unique.insert(*capability) {
            return Err(ModelPackageError::DuplicateCapability);
        }
        let matches_stage = matches!(
            (stage, capability),
            (
                ModelStage::Asr,
                ModelCapability::StreamingAsr | ModelCapability::FileAsr
            ) | (ModelStage::Formatting, ModelCapability::Formatting)
                | (ModelStage::Vad, ModelCapability::Vad)
        );
        if !matches_stage {
            return Err(ModelPackageError::CapabilityStageMismatch);
        }
    }
    Ok(())
}

fn validate_languages(stage: ModelStage, languages: &[String]) -> Result<(), ModelPackageError> {
    if (stage == ModelStage::Asr && languages.is_empty())
        || languages.len() > MAXIMUM_LANGUAGE_COUNT
    {
        return Err(ModelPackageError::InvalidLanguage);
    }
    let mut unique = BTreeSet::new();
    for language in languages {
        if !valid_language(language) {
            return Err(ModelPackageError::InvalidLanguage);
        }
        if !unique.insert(language.to_ascii_lowercase()) {
            return Err(ModelPackageError::DuplicateLanguage);
        }
    }
    Ok(())
}

fn valid_language(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 35
        && !value.starts_with('-')
        && !value.ends_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn validate_license(license: &ManifestLicense) -> Result<(), ModelPackageError> {
    let valid_expression = !license.spdx_expression.trim().is_empty()
        && license.spdx_expression.len() <= 256
        && license
            .spdx_expression
            .chars()
            .all(|character| character.is_ascii() && !character.is_control());
    let source_location = license.source_url.strip_prefix("https://");
    if !valid_expression
        || source_location.is_none_or(str::is_empty)
        || license.source_url.len() > 2_048
        || license
            .source_url
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(ModelPackageError::InvalidLicense);
    }
    validate_relative_path(&license.notice_file)
}

fn validate_resources(resources: &ManifestResources) -> Result<(), ModelPackageError> {
    if resources.minimum_memory_bytes == 0
        || resources.recommended_memory_bytes < resources.minimum_memory_bytes
    {
        return Err(ModelPackageError::InvalidResources);
    }
    Ok(())
}
