mod config;

use crate::config::Configuration;

fn main() {
    // Step 1: load config and print it. Errors for now: just panic with a
    // message. Later steps replace this with proper error handling.
    let config = Configuration::from_env().unwrap();
    println!("{config:#?}");
}
