
import pandas as pd

data = pd.read_csv("consumption.csv", delimiter=';')

print(data.Mængde.apply(lambda d: f"{d} kW"))
print(f"{data.Mængde} kWh")


# Get to a structure of 
 #  ┌─entity_id───────────────────────────┬─state─┬─state_float─┬─attributes──────────────────────────────────────────────────────────────────────┬────────────last_changed─┬────────────last_updated─┬─────────────ingested_at─┐
#1. │ sensor.clickhouse_daily_consumption │ 0     │           0 │ {"day": [], "consumption": [], "friendly_name": "ClickHouse Daily Consumption"} │ 2026-11-07 11:40:34.091 │ 2026-11-07 11:40:34.091 │ 2026-11-07 11:40:38.883 │

new_df = pd.DataFrame({})
new_df['attributes'] = data.Mængde.apply (lambda e: f'{{"quarter":{e}, "friendly_name": "Main consumption"}}') 
new_df['entity_id'] = 'sensor.clickhouse_main_consumption'
new_df['state'] = 0
new_df['state_float'] = 0.0
new_df['ingested_at'] = data['Til dato']
new_df['last_changed'] = data['Til dato']
new_df['last_updated'] = data['Til dato']


print(new_df)
new_df.to_csv("exported_data.csv")

