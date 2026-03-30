defmodule PasskeysWeb.UserLive.Settings do
  use PasskeysWeb, :live_view

  require Logger

  on_mount {PasskeysWeb.UserAuth, :require_sudo_mode}

  alias Passkeys.Accounts

  # Idea here:
  # On mount, need to call challenge = Wax.new_registration_challenge(opts)
  # Store challenge data in the user session via an XHR post to a /passkeys/store-challenge URL
  # rp_id: challenge.rp_id,
  # challenge_b64: Base.encode64(challenge.bytes),
  # attestation: challenge.attestation

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <div id="create-passkey" phx-hook="register_passkey">
        <.button variant="primary" phx-click="create_passkey">
          Create passkey
        </.button>
      </div>

      <h2 class="text-lg font-semibold leading-8">Passkeys</h2>
      <.table id="credentials" rows={@credentials}>
        <:col :let={cred} label="Credential id">{inspect(cred.id)}</:col>
        <:col :let={cred} label="Public key">{inspect(cred.cose_key)}</:col>
        <:col :let={cred} label="Authenticator">{inspect(cred.aaguid)}</:col>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    credentials = Accounts.list_user_credentials(user)
    challenge = Map.get(session, "webauthn_challenge")

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:credentials, credentials)
      |> assign(:challenge, challenge)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("create_passkey", _params, socket) do
    user = socket.assigns.current_scope.user
    challenge = socket.assigns.challenge

    # rp_id should come from Application.get_env...
    socket =
      push_event(socket, "trigger-attestation", %{
        challenge: Base.encode64(challenge.bytes),
        attestation: challenge.attestation,
        rp_id: challenge.rp_id,
        rp_name: "Passkeys",
        user_id: user.id,
        user_email: user.email
      })

    {:noreply, socket}
  end

  # Params coming in as
  # %{"attestation_object" => %{}, "client_data_json" => %{}, "raw_id" => %{}, "type" => "public-key"}
  def handle_event(
        "credential_created",
        %{
          "raw_id" => raw_id_b64,
          "type" => _type,
          "client_data_json" => client_data_json,
          "attestation_object" => attestation_object_b64
        } = params,
        socket
      ) do
    Logger.debug("credential created #{inspect(params)}")

    client_data_json =
      case client_data_json do
        data when is_map(data) -> Jason.encode!(data)
        json_str when is_binary(json_str) -> json_str
        _ -> "{}"
      end

    socket =
      case Accounts.register_credential(
             socket.assigns.current_scope.user,
             socket.assigns.challenge,
             raw_id_b64,
             attestation_object_b64,
             client_data_json
           ) do
        {:ok, _} ->
          put_flash(socket, :info, "Passkey registered successfully")

        {:error, %Ecto.Changeset{} = changeset} ->
          put_flash(socket, :error, "Passkey registration failed: #{inspect(changeset.errors)}")

        {:error, reason} ->
          put_flash(socket, :error, "Passkey registration failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("credential_failed", %{"error" => error} = params, socket) do
    Logger.error("credential failed #{inspect(params)}")

    socket = put_flash(socket, :error, "Passkey creation failed: #{error}")
    {:noreply, socket}
  end
end
