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
    flush_interval: FlushInterval,
    include_attributes: bool,
    #[serde(deserialize_with = "deserialize_entity_set")]
    exclude_entities: HashSet<String>,
    ha: Ha,
    clickhouse: Clickhouse,
}


#[derive(Clone, Debug, Deserialize)]
#[serde(try_from = "u32")]
struct FlushInterval(u32);

#[derive(Clone, Debug, Deserialize)]
#[serde(try_from = "u16")]
struct Port(u16);

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
    port: Port,
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

impl TryFrom<u32> for FlushInterval {
    type Error = String;
    fn try_from(v: u32) -> Result<Self, Self::Error> {
        if v >= 1 {
            Ok(FlushInterval(v))
        } else {
            Err(format!("Flush interval {v} must be >= 1"))
        }
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

impl TryFrom<u16> for Port{
    type Error = String;
    fn try_from(v: u16) -> Result<Self, Self::Error> {
        if (v >= 1000) && (v <= 9999) {
            Ok(Port(v))
        } else {
            Err(format!("Port must be atleast 1000 and no more than 9999. Not {v}."))
        }
    }
}

// serde can hand us the exclude list in two shapes: a comma-separated
// string (env source) or a sequence (TOML source). ingestor.py:74-76
// trims whitespace and drops empty entries; we must reproduce both rules
// here, because the config crate's list_separator does neither and is
// global to all env vars.
fn deserialize_entity_set<'de, D>(deserializer: D) -> Result<HashSet<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct EntitySetVisitor;

    impl<'de> serde::de::Visitor<'de> for EntitySetVisitor {
        type Value = HashSet<String>;

        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a comma-separated string or a list of entity ids")
        }

        fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
            Ok(clean_entity_ids(v.split(',')))
        }

        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> Result<Self::Value, A::Error> {
            let mut set = HashSet::new();
            while let Some(item) = seq.next_element::<String>()? {
                set.extend(clean_entity_ids(std::iter::once(item)));
            }
            Ok(set)
        }
    }

    // deserialize_any: lets the data decide which visit_* method runs,
    // instead of us declaring one input shape up front.
    deserializer.deserialize_any(EntitySetVisitor)
}

fn clean_entity_ids<S: AsRef<str>>(items: impl Iterator<Item = S>) -> HashSet<String> {
    items
        .map(|s| s.as_ref().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn config_path(filename: &str) -> PathBuf {
    std::env::var("CONFIG_DIR")
        .map_or_else(|_| PathBuf::from("config"), PathBuf::from)
        .join(filename)
}


#[cfg(test)]
mod test {
    use super::*;

    /// Every env var that can influence Configuration::from_env().
    /// Used to give each check a clean slate.
    const ALL_ENV_VARS: &[&str] = &[
        "HA__SUPERVISOR_TOKEN",
        "HA__WS_URL",
        "CLICKHOUSE__HOST",
        "CLICKHOUSE__PORT",
        "CLICKHOUSE__PASSWORD",
        "CLICKHOUSE__USER",
        "CLICKHOUSE__DATABASE",
        "CLICKHOUSE__TABLE",
        "BATCH_SIZE",
        "FLUSH_INTERVAL",
        "INCLUDE_ATTRIBUTES",
        "EXCLUDE_ENTITIES",
        "THROTTLE_ENTITIES",
        "CONFIG_DIR",
    ];

    fn set_env(pairs: &[(&str, &str)]) {
        for var in ALL_ENV_VARS {
            std::env::remove_var(var);
        }
        for (k, v) in pairs {
            std::env::set_var(k, v);
        }
    }

    /// Pure unit test: Clickhouse port range (user-defined invariant).
    #[test]
    fn port_must_be_between_1000_and_9999() {
        // Boundaries only: 999 too low, 10000 too high for 4-digit rule.
        assert!(Port::try_from(999).is_err());
        assert_eq!(Port::try_from(1000).unwrap().0, 1000);
        assert_eq!(Port::try_from(9999).unwrap().0, 9999);
        assert!(Port::try_from(10000).is_err());
        // The production value must be valid.
        assert_eq!(Port::try_from(8123).unwrap().0, 8123);
    }

    /// Pure unit test: the BatchSize invariant (Python: max(1, ...) on line 71).
    #[test]
    fn batch_size_must_be_at_least_one() {
        assert!(BatchSize::try_from(0).is_err());
        assert_eq!(BatchSize::try_from(1).unwrap().0, 1);
        assert_eq!(BatchSize::try_from(500).unwrap().0, 500);
    }

    /// The remaining checks mutate process-global env vars; Rust runs tests
    /// in parallel, so they all live in THIS single test function and run
    /// sequentially. Do not add more env-mutating #[test] functions.
    #[test]
    fn env_loading_matches_ingestor_py() {
        // ── 1. Python defaults: BATCH_SIZE=500, FLUSH_INTERVAL=5 (ingestor.py:71-72)
        set_env(&[("CLICKHOUSE__HOST", "ch"), ("HA__SUPERVISOR_TOKEN", "tok")]);
        let config =
            Configuration::from_env().expect("batch_size and flush_interval should have defaults (Python: 500 and 5)");
        assert_eq!(config.batch_size.0, 500);
        assert_eq!(config.flush_interval.0, 5);
        // TOML defaults survive when env is silent (ingestor.py:40-56)
        assert_eq!(config.clickhouse.host, "ch");
        assert_eq!(config.clickhouse.port.0, 8123);
        assert_eq!(config.clickhouse.user, "default");
        assert_eq!(config.clickhouse.database, "homeassistant");
        assert_eq!(config.clickhouse.table, "states");
        assert_eq!(config.ha.ws_url, "ws://supervisor/core/websocket");
        assert!(config.include_attributes);
        // TOML excludes survive the seq path of the deserializer.
        assert!(config.exclude_entities.contains("sensor.sun"));
        assert!(config.exclude_entities.contains("home.user"));

        // ── 2. Overrides + secret redaction: the Debug render must never
        // leak the password (SecretString's whole reason to exist).
        set_env(&[
            ("CLICKHOUSE__HOST", "ch"),
            ("HA__SUPERVISOR_TOKEN", "tok"),
            ("CLICKHOUSE__PASSWORD", "top-secret-value"),
            ("CLICKHOUSE__DATABASE", "mydb"),
        ]);
        let config = Configuration::from_env().expect("valid override env");
        assert_eq!(config.clickhouse.database, "mydb");
        let rendered = format!("{config:#?}");
        assert!(
            !rendered.contains("top-secret-value"),
            "password leaked in Debug output"
        );

        // ── 3. BATCH_SIZE=0 must not load (ingestor.py clamps via max(1, ...))
        set_env(&[
            ("CLICKHOUSE__HOST", "ch"),
            ("HA__SUPERVISOR_TOKEN", "tok"),
            ("BATCH_SIZE", "0"),
        ]);
        assert!(
            Configuration::from_env().is_err(),
            "BATCH_SIZE=0 must be rejected (Python: clamped to 1)"
        );

        // ── 4. FLUSH_INTERVAL=0 must not load as 0 (Python clamps to 1)
        set_env(&[
            ("CLICKHOUSE__HOST", "ch"),
            ("HA__SUPERVISOR_TOKEN", "tok"),
            ("FLUSH_INTERVAL", "0"),
        ]);
        assert!(
            Configuration::from_env().is_err(),
            "FLUSH_INTERVAL=0 must be rejected or clamped to >= 1, not accepted as 0"
        );

        // ── 5. EXCLUDE_ENTITIES: comma-separated, trimmed, empty entries
        // dropped (ingestor.py:74-76)
        set_env(&[
            ("CLICKHOUSE__HOST", "ch"),
            ("HA__SUPERVISOR_TOKEN", "tok"),
            ("EXCLUDE_ENTITIES", " sensor.sun ,, zone.home ,"),
        ]);
        let config = Configuration::from_env().expect("accepts exclude list from env");
        assert!(config.exclude_entities.contains("sensor.sun"));
        assert!(config.exclude_entities.contains("zone.home"));
        assert!(
            !config.exclude_entities.contains(""),
            "empty entries must be dropped"
        );
        assert_eq!(config.exclude_entities.len(), 2);

        // Leave the process clean for any other tests.
        for var in ALL_ENV_VARS {
            std::env::remove_var(var);
        }
    }
}

