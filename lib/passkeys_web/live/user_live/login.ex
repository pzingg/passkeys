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

        <ul class="flex justify-between text-sm font-medium text-center text-body border-b border-default">
          <.tab active={@active_tab} value="passkey">Log in with passkey</.tab>
          <.tab active={@active_tab} value="magic_link">Magic link</.tab>
          <.tab active={@active_tab} value="password">Password</.tab>
        </ul>

        <div :if={@active_tab == "passkey"}>
          <.form
            for={@form}
            id="login_form_passkey"
            action={~p"/users/log-in"}
            phx-hook="authenticate_passkey"
            phx-submit="submit_passkey"
            phx-trigger-action={@trigger_passkey_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={@form[:email]}
              type="email"
              label="Email (optional: filter matching credentials)"
              autocomplete="username"
              spellcheck="false"
              phx-mounted={JS.focus()}
            />
            <input type="hidden" name="user[signature]" value={@passkey_signature} />
            <input type="hidden" name="user[token]" value={@passkey_token} />
            <.button class="btn btn-primary w-full">
              Log in with passkey <span aria-hidden="true">→</span>
            </.button>
          </.form>
        </div>

        <div :if={@active_tab == "magic_link"}>
          <div :if={Passkeys.local_mail_adapter?()} class="alert alert-info">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>You are running the local mail adapter.</p>
              <p>
                To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
              </p>
            </div>
          </div>

          <.form
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button class="btn btn-primary w-full">
              Log in with email <span aria-hidden="true">→</span>
            </.button>
          </.form>
        </div>

        <div :if={@active_tab == "password"}>
          <.form
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_password_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={@form[:email]}
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
        active_tab: "passkey",
        trigger_password_submit: false,
        trigger_passkey_submit: false,
        passkey_signature: "",
        passkey_token: "",
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
        fn token -> url(~p"/users/log-in/#{token}") |> Passkeys.with_wax_origin() end
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("submit_passkey", %{"user" => user_params}, socket) do
    email = Map.get(user_params, "email", "")
    credentials = Accounts.list_user_credentials(%{email: email})

    opts =
      if Enum.empty?(credentials) do
        []
      else
        [allow_credentials: Enum.map(credentials, &UserCredential.public_key_tuple/1)]
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

  def handle_event(
        "credential_selected",
        %{
          "type" => _type,
          "raw_id" => credential_id,
          "client_data_json" => client_data_json,
          "authenticator_data" => authenticator_data_b64,
          "signature" => signature_b64,
          "user_handle" => maybe_user_handle
        },
        socket
      ) do
    authenticator_data_raw = Base.decode64!(authenticator_data_b64)
    signature_raw = Base.decode64!(signature_b64)
    challenge = socket.assigns.webauthn_challenge

    # Notes:
    #
    # `Accounts.get_user_by_handle` checks for missing or invalid formats for
    # `user_handle` (which must be a UUID string) as well as if the user exists
    # in the database. It's probably a better practice to create an additional
    # unique random `handle` string in the `User` schema, and use that rather
    # than exposing the primary key...
    #
    # The public keys that will be checked in `Wax.authenticate` are either from
    # `challenge.allow_credentials`, or if a resident key was used, the
    # list of tuples stored in our database for the credentials registered to the user.
    socket =
      with {:ok, user} <-
             Accounts.get_user_by_handle_or_credential(maybe_user_handle, credential_id),
           aaguids = Enum.map(user.credentials, &UserCredential.aaguid_tuple/1) |> Map.new(),
           {:ok, _name} <-
             check_authenticator_status(credential_id, aaguids, challenge),
           public_keys = Enum.map(user.credentials, &UserCredential.public_key_tuple/1),
           {:ok, authenticator_data} <-
             Wax.authenticate(
               credential_id,
               authenticator_data_raw,
               signature_raw,
               client_data_json,
               challenge,
               public_keys
             ),
           _ = Logger.debug("Wax: successful authentication for challenge #{inspect(challenge)}"),
           {:ok, encoded_token} <-
             Accounts.login_by_passkey(
               user,
               credential_id,
               signature_b64,
               authenticator_data.sign_count
             ) do
        assign(socket,
          passkey_signature: signature_b64,
          passkey_token: encoded_token,
          trigger_passkey_submit: true
        )
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          errors = changeset |> translate_errors() |> Enum.join(" ")
          put_flash(socket, :error, "Passkey authentication failed: #{errors}")

        {:error, reason} ->
          put_flash(socket, :error, "Passkey authentication failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event("credentials_get_failed", %{"error" => error} = params, socket) do
    Logger.error("credentials.get failed #{inspect(params)}")

    socket = put_flash(socket, :error, "Passkey authentication failed: #{error}")
    {:noreply, socket}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :active_tab, tab)
    {:noreply, socket}
  end

  # UI components

  attr :active, :string, required: true
  attr :value, :string, required: true
  slot :inner_block

  def tab(assigns) do
    ~H"""
    <li class="me-2">
      <div
        class={[
          "inline-block p-4 rounded-t-lg",
          (@active == @value && "font-semibold text-brand bg-base-300 active") || "hover:bg-base-300"
        ]}
        aria-current={if @active, do: "page"}
        phx-click="change_tab"
        phx-value-tab={@value}
      >
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  # Private functions

  defp check_authenticator_status(credential_id, aaguids, challenge) do
    case Map.get(aaguids, credential_id) do
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
