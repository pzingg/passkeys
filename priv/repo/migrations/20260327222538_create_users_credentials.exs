defmodule Passkeys.Repo.Migrations.CreateUsersCredentials do
  use Ecto.Migration

  def change do
    create table(:users_credentials, primary_key: false) do
      add :id, :binary, primary_key: true
      add :public_key_spki, :binary, null: false
      add :resident?, :boolean, null: false, default: false
      add :sign_count, :integer, null: false, default: 0

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end
  end
end
