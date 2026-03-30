defmodule PasskeysWeb.UserLive.Login do
  use PasskeysWeb, :live_view

  require Logger

  alias Passkeys.Accounts
  alias Passkeys.Accounts.UserCredential

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                Don't have an account? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-brand hover:underline"
                  phx-no-format
                >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_passkey"
          action={~p"/users/log-in"}
          phx-hook="authenticate_passkey"
          phx-submit="submit_passkey"
          phx-trigger-action={@trigger_passkey_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <input type="hidden" name="user[authenticator]" value={@passkey_authenticator} />
          <input type="hidden" name="user[token]" value={@passkey_token} />
          <input type="hidden" name="user[sign_count]" value={@passkey_sign_count} />
          <.button class="btn btn-primary w-full">
            Log in with passkey <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider">or</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider">or</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_password_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    socket =
      assign(socket,
        form: form,
        trigger_password_submit: false,
        trigger_passkey_submit: false,
        passkey_authenticator: "",
        passkey_token: "",
        passkey_sign_count: 0,
        webauthn_challenge: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_password_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("submit_passkey", %{"user" => %{"email" => email}}, socket) do
    user = Accounts.get_user_by_email(email)
    credentials = Accounts.credentials_for_user_id(user.id)

    opts =
      if Enum.empty?(credentials) do
        []
      else
        [allow_credentials: Enum.map(credentials, &UserCredential.wax_credential/1)]
      end

    challenge = Wax.new_authentication_challenge(opts)

    socket =
      socket
      |> assign(:webauthn_challenge, challenge)
      |> push_event("trigger-authentication", %{
        challenge: Base.encode64(challenge.bytes),
        rp_id: challenge.rp_id,
        cred_ids: Enum.map(credentials, fn credential -> credential.id end)
      })

    {:noreply, socket}
  end

  def handle_event("credential_selected", %{"user_handle" => nil}, socket) do
    Logger.error("credential selected - no handle")

    socket = put_flash(socket, :error, "Passkey registration failed: no user")
    {:noreply, socket}
  end

  def handle_event(
        "credential_selected",
        %{
          "type" => _type,
          "raw_id" => credential_id,
          "client_data_json" => client_data_json,
          "authenticator_data" => authenticator_data_b64,
          "signature" => signature_b64,
          "user_handle" => maybe_user_id
        },
        socket
      ) do
    authenticator_data_raw = Base.decode64!(authenticator_data_b64)
    signature_raw = Base.decode64!(signature_b64)

    challenge = socket.assigns.webauthn_challenge
    credentials = Accounts.credentials_for_user_id(maybe_user_id)
    credentials_from_user_id = Enum.map(credentials, &UserCredential.wax_credential/1)
    cred_id_aaguid_mapping = Enum.map(credentials, &UserCredential.cred_mapping/1) |> Map.new()

    socket =
      with {:ok, authenticator_data} <-
             Wax.authenticate(
               credential_id,
               authenticator_data_raw,
               signature_raw,
               client_data_json,
               challenge,
               credentials_from_user_id
             ),
           {:ok, name} <-
             check_authenticator_status(credential_id, cred_id_aaguid_mapping, challenge) do
        Logger.debug("Wax: successful authentication for challenge #{inspect(challenge)}")

        encoded_token = Accounts.create_passkey_token(maybe_user_id)

        assign(socket,
          passkey_authenticator: name,
          passkey_token: encoded_token,
          passkey_sign_count: authenticator_data.sign_count,
          trigger_passkey_submit: true
        )
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          put_flash(socket, :error, "Passkey registration failed: #{inspect(changeset.errors)}")

        {:error, reason} ->
          put_flash(socket, :error, "Passkey registration failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("credentials_get_failed", %{"error" => error} = params, socket) do
    Logger.error("credentials.get failed #{inspect(params)}")

    socket = put_flash(socket, :error, "Passkey creation failed: #{error}")
    {:noreply, socket}
  end

  defp local_mail_adapter? do
    Application.get_env(:passkeys, Passkeys.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  defp check_authenticator_status(credential_id, cred_id_aaguid_mapping, challenge) do
    case Map.get(cred_id_aaguid_mapping, credential_id) do
      nil ->
        {:ok, "a credential not in database"}

      aaguid ->
        case Wax.Metadata.get_by_aaguid(aaguid, challenge) do
          {:ok, metadata} ->
            {:ok, Map.get(metadata, "description", "Unknown")}

          {:error, _} = error ->
            error
        end
    end
  end
end
