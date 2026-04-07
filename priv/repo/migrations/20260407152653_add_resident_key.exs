defmodule Passkeys.Repo.Migrations.AddResidentKey do
  use Ecto.Migration

  def change do
    alter table("users_credentials") do
      add :resident_key?, :boolean, null: true
    end
  end
end
