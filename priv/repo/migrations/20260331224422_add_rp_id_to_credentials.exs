defmodule Passkeys.Repo.Migrations.AddRpIdToCredentials do
  use Ecto.Migration

  def change do
    alter table("users_credentials") do
      add :rp_id, :string, null: true
    end
  end
end
