defmodule Passkeys.Repo.Migrations.AddAuthenticatorAttachmentAndTransports do
  use Ecto.Migration

  def change do
    alter table("users_credentials") do
      remove :resident?, :boolean, null: false, default: false
      add :attachment, :string, null: true
      add :transports, :string, null: true
    end
  end
end
