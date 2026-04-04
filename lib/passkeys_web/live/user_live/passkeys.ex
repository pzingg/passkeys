defmodule PasskeysWeb.UserLive.Passkeys do
  use PasskeysWeb, :live_view

  require Logger

  alias Passkeys.Accounts
  alias Passkeys.Accounts.UserCredential

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} width_class="w-2/3" current_scope={@current_scope}>
      <div id="register-passkey" phx-hook="register_passkey" phx-update="ignore" />

      <div :if={@live_action != :create}>
        <div class="text-center">
          <.header>
            Passkeys
            <:subtitle>Manage your account passkeys</:subtitle>
          </.header>
        </div>

        <.table
          id="credentials"
          rows={@streams.credentials}
          row_data={fn {_id, credential} -> credential end}
        >
          <:col :let={{_id, credential}} label="Credential id">
            {String.slice(credential.id, 1..6) <> "..."}
          </:col>
          <:col :let={{_id, credential}} label="RP">{credential.rp_id}</:col>
          <:col :let={{_id, credential}} label="Public key">
            {UserCredential.cose_key_to_string(credential)}
          </:col>
          <:col :let={{_id, credential}} label="Authenticator">
            <.authenticator_icon aaguid={Base.encode16(credential.aaguid || "")} />
          </:col>
          <:col :let={{_id, credential}} label="Attachment">
            {credential.attachment}
          </:col>
          <:col :let={{_id, credential}} label="Transports">
            {credential.transports}
          </:col>
          <:col :let={{_id, credential}} label="Resident?">
            <.bool_check value={credential.resident_key?} />
          </:col>
          <:col :let={{_id, credential}} label="Created">
            <.local_time dt={credential.inserted_at} />
          </:col>
          <:col :let={{_id, credential}} label="Sign count">
            {credential.sign_count}
          </:col>
          <:action :let={{id, credential}}>
            <.button
              phx-click={JS.push("delete", value: %{id: credential.id}) |> hide("##{id}")}
              data-confirm="Are you sure?"
            >
              Delete
            </.button>
          </:action>
        </.table>

        <.button
          variant="primary"
          phx-click="register_passkey"
          disabled={!is_nil(@webauthn_challenge)}
        >
          {if is_nil(@webauthn_challenge), do: "Create new passkey", else: "Registering passkey"}
        </.button>

        <div :if={!!@metadata}>
          <h2 class="text-lg font-semibold leading-8">Authenticator Metadata</h2>
          <.button variant="primary" phx-click="hide_metadata">
            Hide
          </.button>
          <pre>
            <%= raw(@metadata) %>
          </pre>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Passkeys.PubSub, "credentials")
    end

    user_id = socket.assigns.current_scope.user.id

    credentials =
      Accounts.list_user_credentials(%{id: user_id})
      |> Enum.map(&maybe_with_td_class(&1))

    socket =
      socket
      |> stream(:credentials, credentials)
      |> assign(:webauthn_challenge, nil)
      |> assign(:metadata, nil)
      |> maybe_begin_passkey_registration()

    # socket = push_event(socket, "get-client-capabilities", %{})

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _session, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("register_passkey", _params, socket) do
    socket = begin_passkey_registration(socket)
    {:noreply, socket}
  end

  def handle_event(
        "credential_created",
        %{
          "type" => _type,
          "raw_id" => raw_id_b64,
          "client_data_json" => client_data_json,
          "attestation_object" => attestation_object_b64,
          "attachment" => attachment,
          "transports" => transports,
          "resident_key" => resident_key?
        },
        socket
      ) do
    challenge = socket.assigns.webauthn_challenge
    Logger.error("resident_key? #{resident_key?}")

    socket =
      case Accounts.register_user_credential(
             socket.assigns.current_scope.user,
             challenge,
             raw_id_b64,
             attestation_object_b64,
             client_data_json,
             attachment,
             transports,
             resident_key?,
             delete_stale?: true
           ) do
        {:ok, _credential} ->
          Logger.debug("Wax: successful registration for challenge #{inspect(challenge)}")
          put_flash(socket, :info, "Passkey registered successfully")

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = changeset |> translate_errors() |> Enum.join(" ")
          put_flash(socket, :error, "Passkey registration failed: #{errors}")

        {:error, reason} ->
          Logger.error("Passkey registration failed: #{inspect(reason)}")
          put_flash(socket, :error, "Passkey registration failed: #{inspect(reason)}")
      end

    {:noreply, end_passkey_registration(socket)}
  end

  def handle_event("credentials_create_failed", %{"error" => error} = params, socket) do
    Logger.error("credentials.create failed #{inspect(params)}")

    socket =
      socket
      |> put_flash(:error, "Passkey creation failed: #{error}")
      |> end_passkey_registration()

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => credential_id}, socket) do
    credential = Accounts.get_user_credential!(credential_id)
    _ = Accounts.delete_user_credential(credential)
    socket = stream_delete(socket, :credentials, credential)

    {:noreply, socket}
  end

  def handle_event("show_metadata", %{"aaguid" => aaguid}, socket) do
    metadata = aaguid |> Base.decode16!() |> fido2_metadata() |> Jason.encode!(pretty: true)
    socket = assign(socket, :metadata, metadata)

    {:noreply, socket}
  end

  def handle_event("hide_metadata", _params, socket) do
    socket = assign(socket, :metadata, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:credential_created, credential, deleted_count}, socket) do
    socket =
      if deleted_count == 0 do
        credential = maybe_with_td_class(credential)
        stream_insert(socket, :credentials, credential)
      else
        user_id = socket.assigns.current_scope.user.id

        credentials =
          Accounts.list_user_credentials(%{id: user_id})
          |> Enum.map(&maybe_with_td_class(&1))

        stream(socket, :credentials, credentials, reset: true)
      end

    {:noreply, socket}
  end

  def handle_info({:credential_updated, credential}, socket) do
    credential = maybe_with_td_class(credential)
    socket = stream_insert(socket, :credentials, credential, at: -1)

    {:noreply, socket}
  end

  def handle_info({:credential_deleted, credential}, socket) do
    socket = stream_delete(socket, :credentials, credential)

    {:noreply, socket}
  end

  # UI components

  attr :dt, DateTime, required: true

  def local_time(assigns) do
    dt = DateTime.shift_zone!(assigns.dt, "America/Los_Angeles")

    assigns =
      assigns
      |> Map.put(:day, Calendar.strftime(dt, "%d %b %Y"))
      |> Map.put(:time, Calendar.strftime(dt, "%I:%M %p"))

    ~H"""
    <div class="localtime-day">{@day}</div>
    <div class="localtime-time">{@time}</div>
    """
  end

  attr :value, :boolean

  def bool_check(%{value: true} = assigns) do
    ~H"""
    <.icon name="hero-check" class="size-5" />
    """
  end

  def bool_check(%{value: nil} = assigns) do
    ~H"""
    <.icon name="hero-question-mark-circle" class="size-5" />
    """
  end

  def bool_check(assigns) do
    ~H"""
    <.icon name="hero-x-mark" class="size-5" />
    """
  end

  attr :aaguid, :string, required: true

  def authenticator_icon(assigns) do
    metadata = assigns.aaguid |> Base.decode16!() |> fido2_metadata()

    assigns =
      assigns
      |> Map.put(:icon, Map.fetch!(metadata, "icon"))
      |> Map.put(:description, Map.fetch!(metadata, "description"))

    ~H"""
    <div class="cursor-pointer" phx-click="show_metadata" phx-value-aaguid={@aaguid}>
      <div><img class="max-w-10" src={@icon} /></div>
      <div>{@description}</div>
    </div>
    """
  end

  # Private functions

  defp maybe_begin_passkey_registration(%{assigns: %{live_action: :create}} = socket) do
    begin_passkey_registration(socket)
  end

  defp maybe_begin_passkey_registration(socket), do: socket

  defp end_passkey_registration(%{assigns: %{live_action: :create}} = socket) do
    socket
    |> assign(:webauthn_challenge, nil)
    |> push_patch(to: ~p"/users/passkeys")
  end

  defp end_passkey_registration(socket), do: assign(socket, :webauthn_challenge, nil)

  defp begin_passkey_registration(socket) do
    user = socket.assigns.current_scope.user
    challenge = Wax.new_registration_challenge(attestation: "indirect")

    # It's probably a better practice to create an additional unique random `handle`
    # string in the `User` schema, and use that rather than exposing the
    # primary key...
    socket
    |> assign(:webauthn_challenge, challenge)
    |> push_event("trigger-attestation", %{
      challenge: Base.encode64(challenge.bytes),
      attestation: challenge.attestation,
      rp_id: challenge.rp_id,
      rp_name: "Passkeys",
      user_handle: user.id,
      user_email: user.email
    })
  end

  @unknown_icon "data:image/png;base64,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"

  defp fido2_metadata(aaguid) when is_nil(aaguid) or aaguid == "" do
    %{"description" => "No aaguid provided", "icon" => @unknown_icon}
  end

  defp fido2_metadata(aaguid) do
    metadata =
      case Wax.Metadata.get_by_aaguid(aaguid) do
        {:ok, meta} -> meta
        _ -> %{"aaguid" => aaguid}
      end

    metadata
    |> Map.put_new("description", "Unknown: no metadata for #{aaguid}")
    |> Map.put_new("icon", @unknown_icon)
  end

  defp maybe_with_td_class(credential) do
    if credential.rp_id == Passkeys.wax_rp_id() do
      credential
    else
      Map.put(credential, :RP, %{td_class: "text-red-600"})
    end
  end
end
