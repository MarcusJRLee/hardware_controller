use std::{
    fmt,
    path::{Path, PathBuf},
};

use crate::{
    ModelCapability, ModelFileRole, ModelPackageError, ModelPackageLimits, ModelRuntime,
    ModelStage, validate_model_package,
};

/// A package that is ready for the completed-file ASR runtime.
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
    /// Verified absolute speech-detection payload path, when packaged.
    pub speech_detection_path: Option<PathBuf>,
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
    /// The package declares more than one speech-detection payload.
    AmbiguousSpeechDetectionPayload,
}

impl fmt::Display for ASRModelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ASR model resolution failed: {self:?}")
    }
}

impl std::error::Error for ASRModelError {}

/// Revalidates and resolves one transcribe.cpp completed-file ASR package.
///
/// The returned paths remain trustworthy only while the caller prevents
/// concurrent mutation of the private installed package.
///
/// # Errors
///
/// Returns a typed failure for any package-integrity or compatibility error.
pub fn resolve_file_asr_model(
    root: &Path,
    limits: ModelPackageLimits,
    expected_manifest_sha256: [u8; 32],
) -> Result<ResolvedASRModel, ASRModelError> {
    let package = validate_model_package(root, limits, Some(expected_manifest_sha256))
        .map_err(ASRModelError::Package)?;
    if package.runtime != ModelRuntime::TranscribeCpp {
        return Err(ASRModelError::UnsupportedRuntime);
    }
    if package.stage != ModelStage::Asr {
        return Err(ASRModelError::UnsupportedStage);
    }
    if !package.capabilities.contains(&ModelCapability::FileAsr) {
        return Err(ASRModelError::MissingFileCapability);
    }
    let paths_with_role = |role: ModelFileRole| {
        package
            .files
            .iter()
            .filter(|file| file.role == role)
            .map(|file| root.join(&file.path))
            .collect::<Vec<_>>()
    };
    let model_paths = paths_with_role(ModelFileRole::Model);
    let [model_path] = model_paths.as_slice() else {
        return Err(ASRModelError::AmbiguousModelPayload);
    };
    let speech_detection_path = match paths_with_role(ModelFileRole::SpeechDetection).as_slice() {
        [] => None,
        [path] => Some(path.clone()),
        _ => return Err(ASRModelError::AmbiguousSpeechDetectionPayload),
    };
    Ok(ResolvedASRModel {
        package_id: package.package_id,
        version: package.version,
        manifest_sha256: package.manifest_sha256,
        model_path: model_path.clone(),
        speech_detection_path,
    })
}
