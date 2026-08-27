//! Portable validation for local Voice model packages.

mod model_package;
mod model_package_file_system;

pub use model_package::{
    ModelCapability, ModelLicense, ModelPackageError, ModelPackageLimits, ModelResources,
    ModelRuntime, ModelStage, ValidatedModelPackage, validate_model_package,
};

#[cfg(test)]
mod model_package_file_system_test;
#[cfg(test)]
mod model_package_test;
#[cfg(test)]
mod model_package_test_support;
