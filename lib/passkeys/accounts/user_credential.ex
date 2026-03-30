defmodule Passkeys.Accounts.UserCredential do
  @moduledoc """
  A WebAuthn credential belonging to a particular user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Use a binary as the ID, since that's what we get from WebAuthn for the credential.
  @primary_key {:id, :binary_id, []}
  @foreign_key_type :binary_id
  schema "users_credentials" do
    # DER Subject Public Key Info: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.7
    field :cose_key, :map
    field :aaguid, :binary
    field :resident?, :boolean
    field :sign_count, :integer

    belongs_to :user, Passkeys.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:id, :cose_key, :aaguid, :resident?, :sign_count, :user_id])
  end
end
