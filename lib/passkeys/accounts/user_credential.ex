defmodule Passkeys.Accounts.UserCredential do
  @moduledoc """
  A WebAuthn credential belonging to a particular user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Use a binary as the ID, since that's what we get from WebAuthn for the credential.
  @primary_key {:id, :string, []}
  @derive {Phoenix.Param, key: :id}
  @foreign_key_type :binary_id
  schema "users_credentials" do
    field :rp_id, :string
    field :cose_key, :map
    field :aaguid, :binary
    field :attachment, :string
    field :transports, :string
    field :resident_key?, :boolean
    field :sign_count, :integer

    belongs_to :user, Passkeys.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :rp_id,
      :cose_key,
      :aaguid,
      :attachment,
      :transports,
      :resident_key?,
      :sign_count
    ])
  end

  def public_key_tuple(credential) do
    {credential.id, decode_cose_key(credential.cose_key)}
  end

  def aaguid_tuple(credential) do
    {credential.id, credential.aaguid}
  end

  @cose_kty 1
  @cose_alg 3
  @cose_curve -1

  @cose_key_type_OKP 1
  @cose_key_type_EC2 2
  @cose_key_type_RSA 3

  @cose_alg_string %{
    -65535 => "RSASSA-PKCS1-v1_5 w/ SHA-1",
    -259 => "RS512 (TEMPORARY - registered 2018-04-19, expires 2019-04-19)",
    -258 => "RS384 (TEMPORARY - registered 2018-04-19, expires 2019-04-19)",
    -257 => "RS256 (TEMPORARY - registered 2018-04-19, expires 2019-04-19)",
    -47 => "ES256K",
    -39 => "PS512",
    -38 => "PS384",
    -37 => "PS256",
    -36 => "ES512",
    -35 => "ES384",
    -8 => "EdDSA",
    -7 => "ES256"
  }

  @cose_ec_named_curves %{
    1 => :secp256r1,
    2 => :secp384r1,
    3 => :secp521r1,
    6 => :ed25519,
    7 => :ed448,
    8 => :secp256k1
  }

  def cose_key_to_string(credential) do
    cose_key = decode_cose_key(credential.cose_key)
    alg = Map.fetch!(cose_key, @cose_alg)
    kty = Map.fetch!(cose_key, @cose_kty)
    curve = Map.get(cose_key, @cose_curve)

    alg_string = Map.get(@cose_alg_string, alg, "Unknown: #{alg}")

    kty_string =
      case kty do
        @cose_key_type_OKP -> "OKP"
        @cose_key_type_EC2 -> "EC2"
        @cose_key_type_RSA -> "RSA"
        _ -> "Unknown: #{kty}"
      end

    curve_string =
      if is_integer(curve) do
        Map.get(@cose_ec_named_curves, curve, "Unknown: #{curve}")
      else
        ""
      end

    # cose_key = Map.drop(cose_key, [@cose_alg, @cose_kty, @cose_curve])
    "#{kty_string} #{alg_string} #{curve_string}"
  end

  def encode_cose_key(cose_key) do
    cose_key
    |> Enum.map(fn {i, value} ->
      if is_integer(value) do
        {to_string(i), value}
      else
        {to_string(i), "base64:" <> Base.encode64(value, padding: false)}
      end
    end)
    |> Map.new()
  end

  def decode_cose_key(cose_key) do
    cose_key
    |> Enum.map(fn {i, value} ->
      case value do
        "base64:" <> b64 ->
          {String.to_integer(i), Base.decode64!(b64, padding: false)}

        _ ->
          {String.to_integer(i), value}
      end
    end)
    |> Map.new()
  end
end
