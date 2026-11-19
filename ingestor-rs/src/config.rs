use config::{self, ConfigError};
use secrecy::SecretString;
use serde::Deserialize;
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

#[derive(Deserialize, Debug)]
pub struct Configuration {
    batch_size: BatchSize,
    flush_interval: u32,
    include_attributes: bool,
    exclude_entities: HashSet<String>,
    ha: Ha,
    clickhouse: Clickhouse,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(try_from = "u32")]
struct BatchSize(u32);

#[derive(Deserialize, Debug)]
struct Ha {
    supervisor_token: String,
    ws_url: String,
}

#[derive(Deserialize, Debug)]
struct Clickhouse {
    host: String,
    port: String,
    user: String,
    password: SecretString,
    database: String,
    table: String,
}

impl Configuration {
    pub fn from_env() -> Result<Configuration, ConfigError> {
        let config_file = config::Config::builder()
            .add_source(config::File::with_name(
                &config_path("default_configuration.toml").to_string_lossy(),
            ))
            .add_source(
                config::Environment::default()
                    .separator("__")
                    .try_parsing(true),
            )
            .build()?;

        let configs: Configuration = config_file.try_deserialize()?;
        Ok(configs)
    }
}

impl TryFrom<u32> for BatchSize {
    type Error = String;
    fn try_from(v: u32) -> Result<Self, Self::Error> {
        if v >= 1 {
            Ok(BatchSize(v))
        } else {
            Err(format!("Batch size value {v} must be >= 1"))
        }
    }
}

fn config_path(filename: &str) -> PathBuf {
    std::env::var("CONFIG_DIR")
        .map_or_else(|_| PathBuf::from("config"), PathBuf::from)
        .join(filename)
}


#[cfg(test)]
mod test {

    #[test]
    fn test_check_batch_size() {

    }

}

