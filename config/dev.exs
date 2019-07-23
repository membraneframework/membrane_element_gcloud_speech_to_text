use Mix.Config

creds_path = Path.expand("./creds.json", __DIR__)
config :goth, json: creds_path |> File.read!()
