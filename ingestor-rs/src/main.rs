mod config;
mod clickhouse;

use crate::config::Configuration;
use crate::clickhouse::ClickhouseClient;

#[tokio::main]
async fn main() {


    let config = Configuration::from_env().unwrap();

    let client = ClickhouseClient::new(&config);
    match client.ensure_schema(&config).await {
        Ok(s) => println!("{}",s),
        Err(err) => println!("Something went wrong: {:?}", err),
    }

}
