defmodule Passkeys.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Passkeys.Repo
  alias Passkeys.Accounts.{User, UserCredential, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user. Returns {:ok, user} or error tuple.

  `handle` is the UUID string (including hyphens), Base64 encoded.

  It's probably a better practice to create an additional
  unique random `handle` string in the `User` schema, and
  use that rather than exposing the primary key...
  """
  def get_user_by_handle(handle) when is_binary(handle) and handle != "" do
    try do
      handle = Base.decode64!(handle)

      query =
        User
        |> where([u], u.id == ^handle)
        |> preload([u], :credentials)

      case Repo.one(query) do
        %User{} = user -> {:ok, user}
        _ -> {:error, :user_not_found}
      end
    rescue
      _ ->
        {:error, :invalid_user_handle}
    end
  end

  def get_user_by_handle(_), do: {:error, :no_user_handle}

  @doc """
  Gets a single user. Returns {:ok, user} or error tuple.
  """
  def get_user_by_credential_id(credential_id) do
    try do
      query =
        User
        |> join(:left, [u], c in assoc(u, :credentials))
        |> where([u, c], c.id == ^credential_id)
        |> preload([u], :credentials)

      case Repo.one(query) do
        %User{} = user -> {:ok, user}
        _ -> {:error, :user_not_found}
      end
    rescue
      _ ->
        if is_nil(credential_id) || credential_id == "" do
          {:error, :no_credential_id}
        else
          {:error, :invalid_credential_id}
        end
    end
  end

  @doc """
  Gets a single user. Returns {:ok, user} or error tuple
  """
  def get_user_by_handle_or_credential(handle, credential_id) do
    case get_user_by_handle(handle) do
      {:ok, user} ->
        {:ok, user}

      _error ->
        get_user_by_credential_id(credential_id)
    end
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Passkeys.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Passkeys.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    unconfirmed_with_password_message = """
    magic link log in is not allowed for unconfirmed users with a password set!

    This cannot happen with the default implementation, which indicates that you
    might have adapted the code to a different use case. Please make sure to read the
    "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
    """

    process_token_query(query, unconfirmed_with_password_message)
  end

  def login_user_by_passkey(token, signature) do
    {:ok, query} = UserToken.verify_passkey_token_query(token, signature)

    unconfirmed_with_password_message =
      "passkey log in is not allowed for unconfirmed users with a password set!"

    process_token_query(query, unconfirmed_with_password_message)
  end

  defp process_token_query(query, exception_message) do
    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise exception_message

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## User credentials

  @doc """
  List WebAuthn credentials for a user.
  """
  def list_user_credentials(%{id: user_id}) when is_binary(user_id) and user_id != "" do
    UserCredential
    |> where([c], c.user_id == ^user_id)
    |> Repo.all()
  end

  def list_user_credentials(%{email: email}) when is_binary(email) and email != "" do
    UserCredential
    |> join(:left, [c], u in assoc(c, :user))
    |> where([c, u], u.email == ^email)
    |> Repo.all()
  end

  def list_user_credentials(_), do: []

  @doc """
  List WebAuthn credentials for a user. Returns `{:ok, credentials}`
  only if the credential list is non-empty and contains the given credential id.
  """
  def list_user_credentials_ok(user_id, credential_id) do
    case list_user_credentials(%{id: user_id}) do
      [] ->
        {:error, :credential_not_found}

      credentials ->
        case Enum.find(credentials, fn credential -> credential.id == credential_id end) do
          %UserCredential{} -> {:ok, credentials}
          _ -> {:error, :credential_not_found}
        end
    end
  end

  @doc """
  Gets a single user credential, preloading the associated user.
  Raises `Ecto.NoResultsError` on error.
  """
  def get_user_credential!(id) do
    query =
      UserCredential
      |> where([c], c.id == ^id)
      |> preload([c], :user)

    case Repo.one(query) do
      %UserCredential{} = credential -> credential
      _ -> raise Ecto.NoResultsError, queryable: UserCredential, query: query
    end
  end

  @doc """
  Registers and creates a new user credential.
  """
  def register_user_credential(
        %User{id: user_id},
        %{rp_id: rp_id} = challenge,
        raw_id_b64,
        attestation_object_b64,
        client_data_json,
        attachment,
        transports,
        resident_key?,
        opts \\ []
      ) do
    attestation_object = Base.decode64!(attestation_object_b64)
    transports = Enum.join(transports, ", ")

    # {:ok, att_data, _} = Wax.Utils.CBOR.decode(attestation_object)
    # Logger.debug("Wax: attestation object #{inspect(att_data)}")
    # Logger.debug("Wax: client_data_json #{inspect(client_data_json)}")

    with {:ok, {authenticator_data, result}} <-
           Wax.register(attestation_object, client_data_json, challenge),
         _ =
           Logger.debug(
             "Wax: attestation object validated with result #{inspect(result)} " <>
               " and authenticator data #{inspect(authenticator_data)}"
           ),
         cose_key =
           UserCredential.encode_cose_key(
             authenticator_data.attested_credential_data.credential_public_key
           ),
         maybe_aaguid = Wax.AuthenticatorData.get_aaguid(authenticator_data),
         attrs = %{
           rp_id: rp_id,
           cose_key: cose_key,
           aaguid: maybe_aaguid,
           attachment: attachment,
           transports: transports,
           resident_key?: resident_key?
         },
         changeset =
           %UserCredential{id: raw_id_b64, user_id: user_id} |> change_user_credential(attrs),
         {:ok, credential} <- Repo.insert(changeset) do
      deleted_count =
        if Keyword.get(opts, :prune_stale_credentials?, false) do
          delete_stale_user_credentials(credential) |> elem(0)
        else
          0
        end

      Phoenix.PubSub.broadcast(
        Passkeys.PubSub,
        "credentials",
        {:credential_created, credential, deleted_count}
      )

      {:ok, credential}
    end
  end

  @doc """
  Updates a user credential.
  """
  def update_user_credential(credential, attrs) do
    case change_user_credential(credential, attrs) |> Repo.update() do
      {:ok, credential} ->
        Phoenix.PubSub.broadcast(
          Passkeys.PubSub,
          "credentials",
          {:credential_updated, credential}
        )

        {:ok, credential}

      error ->
        error
    end
  end

  @doc """
  Deletes a user credential.
  """
  def delete_user_credential(credential) do
    case Repo.delete(credential) do
      {:ok, credential} ->
        Phoenix.PubSub.broadcast(
          Passkeys.PubSub,
          "credentials",
          {:credential_deleted, credential}
        )

        {:ok, credential}

      error ->
        error
    end
  end

  @doc """
  Deletes previous user credentials with same user, RP and aaguid.
  """
  def delete_stale_user_credentials(%{
        user_id: user_id,
        rp_id: rp_id,
        aaguid: aaguid,
        id: except_credential_id
      })
      when is_binary(aaguid) do
    UserCredential
    |> where([c], c.user_id == ^user_id)
    |> where([c], c.rp_id == ^rp_id)
    |> where([c], c.aaguid == ^aaguid)
    |> where([c], c.id != ^except_credential_id)
    |> Repo.delete_all()
  end

  def delete_stale_user_credentials(_), do: {0, nil}

  @doc """
  Returns an `%Ecto.Changeset{}` for inserting or updating a user credential.
  """
  def change_user_credential(credential, attrs \\ %{}) do
    UserCredential.changeset(credential, attrs)
  end

  @doc """
  Updates the sign count for a validated user_credential, then creates and returns a login token.
  """
  def login_by_passkey(user, credential_id, signature, sign_count) do
    Repo.transact(fn ->
      with {:ok, _} <-
             update_user_credential(%UserCredential{id: credential_id}, %{sign_count: sign_count}),
           {:ok, encoded_token} <- create_passkey_token(user, signature) do
        {:ok, encoded_token}
      end
    end)
  end

  defp create_passkey_token(user, signature) do
    {encoded_token, user_token} = UserToken.build_hashed_token(user, "login", signature)

    case Repo.insert(user_token) do
      {:ok, _} -> {:ok, encoded_token}
      error -> error
    end
  end
end
