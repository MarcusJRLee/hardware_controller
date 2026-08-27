use std::{
    fmt,
    path::{Path, PathBuf},
};

use crate::{
    ModelCapability, ModelFileRole, ModelPackageError, ModelPackageLimits, ModelRuntime,
    ModelStage, validate_model_package,
};

/// A package that is ready for one completed-file ASR runtime.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedASRModel {
    /// Stable package identifier.
    pub package_id: String,
    /// Publisher-controlled package version.
    pub version: String,
    /// SHA-256 of the exact revalidated manifest bytes.
    pub manifest_sha256: [u8; 32],
    /// Verified absolute model payload path.
    pub model_path: PathBuf,
}

/// Failure to resolve one installed package for completed-file ASR.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ASRModelError {
    /// Package verification failed before any runtime could load it.
    Package(ModelPackageError),
    /// The package targets a different inference runtime.
    UnsupportedRuntime,
    /// The package does not implement speech recognition.
    UnsupportedStage,
    /// The package cannot recognize a completed audio file.
    MissingFileCapability,
    /// The runtime cannot choose one unambiguous model payload.
    AmbiguousModelPayload,
}

impl fmt::Display for ASRModelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ASR model resolution failed: {self:?}")
    }
}

impl std::error::Error for ASRModelError {}

/// Revalidates and resolves one whisper.cpp completed-file ASR package.
///
/// The returned path remains trustworthy only while the caller prevents
/// concurrent mutation of the private installed package.
///
/// # Errors
///
/// Returns a typed failure for any package-integrity or compatibility error.
pub fn resolve_whisper_file_asr_model(
    root: &Path,
    limits: ModelPackageLimits,
    expected_manifest_sha256: [u8; 32],
) -> Result<ResolvedASRModel, ASRModelError> {
    let package = validate_model_package(root, limits, Some(expected_manifest_sha256))
        .map_err(ASRModelError::Package)?;
    if package.runtime != ModelRuntime::WhisperCpp {
        return Err(ASRModelError::UnsupportedRuntime);
    }
    if package.stage != ModelStage::Asr {
        return Err(ASRModelError::UnsupportedStage);
    }
    if !package.capabilities.contains(&ModelCapability::FileAsr) {
        return Err(ASRModelError::MissingFileCapability);
    }
    let model_paths = package
        .files
        .iter()
        .filter(|file| file.role == ModelFileRole::Model)
        .map(|file| root.join(&file.path))
        .collect::<Vec<_>>();
    let [model_path] = model_paths.as_slice() else {
        return Err(ASRModelError::AmbiguousModelPayload);
    };
    Ok(ResolvedASRModel {
        package_id: package.package_id,
        version: package.version,
        manifest_sha256: package.manifest_sha256,
        model_path: model_path.clone(),
    })
}
