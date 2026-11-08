import sys
import pandas as pd

data = pd.DataFrame([])
for fn in sys.argv[1:]:
    print(f"loading file: {fn}")
    df = pd.read_excel(fn)
    if not df.empty :
        data = pd.concat([data,df]) 
    
#print(data.Mængde.apply(lambda d: f"{d} kW"))
print("Done loading")
print(data)

if data.empty:
    print("Dataframe is empty")
else :
    # Get to a structure of 
    #  ┌─entity_id───────────────────────────┬─state─┬─state_float─┬─attributes──────────────────────────────────────────────────────────────────────┬────────────last_changed─┬────────────last_updated─┬─────────────ingested_at─┐
    #1. │ sensor.clickhouse_daily_consumption │ 0     │           0 │ {"day": [], "consumption": [], "friendly_name": "ClickHouse Daily Consumption"} │ 2026-11-07 11:40:34.091 │ 2026-11-07 11:40:34.091 │ 2026-11-07 11:40:38.883 │
    attr = (f'{{"unit": "kWh", "meter_id": {data.Aftagenummer.unique()[0]} }}')

    new_df = pd.DataFrame( 
                      columns= ['attributes', 
                                'entity_id', 
                                'state',
                                'state_float',
                                'ingested_at',
                                'last_changed',
                                'last_updated']
                      )
    new_df = new_df.astype(dtype= {
                      'attributes':'str',
                      'entity_id':'str',
                      'state':'int',
                      'state_float':'float',
                      'ingested_at':'str',
                      'last_changed':'str',
                      'last_updated':'str',
                      })
    new_df['state_float'] = data.Mængde 
    print(new_df.dtypes)
    new_df['entity_id'] = "sensor.clickhouse_main_consumption_nrgi"
    new_df['attributes'] = attr
    new_df['state'] = data.Mængde
    new_df['ingested_at'] = data['Til dato']
    new_df['last_changed'] = data['Til dato']
    new_df['last_updated'] = data['Til dato']

    print(new_df.state)

    new_df.to_csv("exported_data.csv")

