//! Portable validation for local Voice model packages.

mod asr_model;
mod model_package;
mod model_package_file_system;

pub use asr_model::{ASRModelError, ResolvedASRModel, resolve_whisper_file_asr_model};
pub use model_package::{
    ModelCapability, ModelFileRole, ModelLicense, ModelPackageError, ModelPackageLimits,
    ModelResources, ModelRuntime, ModelStage, ValidatedModelFile, ValidatedModelPackage,
    validate_model_package,
};

#[cfg(test)]
mod asr_model_test;
#[cfg(test)]
mod model_package_file_system_test;
#[cfg(test)]
mod model_package_test;
#[cfg(test)]
mod model_package_test_support;
