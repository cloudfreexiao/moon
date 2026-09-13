use derive_more::From;

pub type Result<T> = core::result::Result<T, Error>;

#[derive(Debug, From)]
pub enum Error {
    #[from]
    Custom(String),

    #[from]
    Io(std::io::Error),

    #[from]
    NulError(std::ffi::NulError),

    /// The process should terminate with this code (see `moon.exit` / shutdown
    /// events). It is a dedicated variant — not a `Custom` whose text happens
    /// to parse as a number — so a numeric-looking error message is never
    /// mistaken for an exit code and swallowed without being reported.
    ExitCode(i32),
}

// region:    --- Custom

impl Error {
    pub fn custom_from_err(err: impl std::error::Error) -> Self {
        Self::Custom(err.to_string())
    }

    pub fn custom(val: impl Into<String>) -> Self {
        Self::Custom(val.into())
    }
}

impl From<&str> for Error {
    fn from(val: &str) -> Self {
        Self::Custom(val.to_string())
    }
}

// endregion: --- Custom

// region:    --- Error Boilerplate

impl core::fmt::Display for Error {
    fn fmt(&self, fmt: &mut core::fmt::Formatter) -> core::result::Result<(), core::fmt::Error> {
        match self {
            Self::Custom(message) => fmt.write_str(message),
            Self::Io(error) => error.fmt(fmt),
            Self::NulError(error) => error.fmt(fmt),
            Self::ExitCode(code) => write!(fmt, "exit code {code}"),
        }
    }
}

impl std::error::Error for Error {}

// endregion: --- Error Boilerplate

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_omits_variant_prefix_for_custom() {
        let error = Error::custom("bootstrap file not found: main.lua");
        assert_eq!(error.to_string(), "bootstrap file not found: main.lua");
    }

    #[test]
    fn display_delegates_to_wrapped_io_error() {
        let inner = std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
        let error = Error::Io(inner);
        assert_eq!(error.to_string(), "no such file");
        assert!(!error.to_string().contains("Io"));
    }

    #[test]
    fn display_delegates_to_wrapped_nul_error() {
        let error = Error::NulError(std::ffi::CString::new("a\0b").unwrap_err());
        assert_eq!(
            error.to_string(),
            "nul byte found in provided data at position: 1"
        );
        assert!(!error.to_string().contains("NulError"));
    }

    #[test]
    fn display_renders_exit_code() {
        let error = Error::ExitCode(-1);
        assert_eq!(error.to_string(), "exit code -1");
    }
}
