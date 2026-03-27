defmodule Passkeys.Repo do
  use Ecto.Repo,
    otp_app: :passkeys,
    adapter: Ecto.Adapters.Postgres
end
