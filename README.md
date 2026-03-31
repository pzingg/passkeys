# Passkeys

Experimenting with WebAuthn passkeys in a Phoenix LiveView test application.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Development notes

The Phoenix LiveView app was created with `mix phx.new` and `mix phx.gen.auth`, and uses the [`wax_` library](https://github.com/tanguilp/wax). The logic for creating and authenticating passkeys was adapted from the [`wax_demo` application](https://github.com/tanguilp/wax_demo), but uses LiveView, instead of controlllers, communicating between backend and frontend with LiveView's `push_event/4` function and LiveView hook's Javascript `pushEvent` method.

Passkeys are created on the account settings live view, and authenticated on the login live view.

Passkey data (authenticator aaguid, public key, sign count) are stored in the Ecto `UserCredential` schema, which references the `User`.

I also consulted the source code for Google's [`passkeys-demo` node-based application](https://github.com/GoogleChromeLabs/passkeys-demo) for other information. A live sandbox of the `passkeys-demo` code is available at https://passkeys-demo.appspot.com 

`passkeys-demo` uses the Javascript PublicKeyCredential API and the [`simplewebauthn` node package](https://simplewebauthn.dev/docs/packages/server)

For testing, I am using the Enpass password manager installed with its Google Chrome and Firefox browser extensions.

In order to work with the Enpass extension, the server must be hosted on an SSL domain, not localhost. On localhost you will see only the "Passkeys & Security Keys" dialog in Chrome, or a dialog that says "Touch your security key to continue with localhost" in Firefox, allowing you to use a Yubikey or other authenticator device.

 I have used [ngrok free](https://ngrok.com/) to create a tunnel betweent the localhost dev server and an HTTPS url.

The `wax_` configuration must be set to the correct origin in this setup.  The `wax_` configuration specifies `rp_id: :auto` and will parse the passkey RP domain from whatever is specified in its `:origin` configuration. I use the environment variable `WAX_ORIGIN` to override the default setting of `origin: http://localhost:4000` (where the Phoenix LiveView dev server normally runs).

If you don't set the origin correctly you will get a failure message:

"The relying party ID is not a registrable domain suffix of, nor equal to the current domain. Subsequently, the .well-known/webauthn resource of the claimed RP ID had the wrong content-type. (It should be application/json.)".

### Registering a new passkey

Passkey registration can be offered:

1. At the end of a new account registration process, or
2. At the end of a log in process, after you have already authenticated (logged in) by other means (magic link or password)
3. From the account settings page, after you have authenticated by other means

#### Options for navigator.credentials.create

Here is the JSON for the options sent by `passkeys-demo`:

```json
{
  "publicKey": {
    "attestation": "none",
    "authenticatorSelection": {
      "authenticatorAttachment": "platform",
      "requireResidentKey": true
    },
    "challenge": {},
    "excludeCredentials": [],
    "extensions": {
      "credProps": true,
      "enforceCredentialProtectionPolicy": false
    },
    "hints": [],
    "pubKeyCredParams": [
      { "alg": -8, "type": "public-key" },
      { "alg": -7, "type": "public-key" },
      { "alg": -257, "type": "public-key" }
    ],
    "rp": {
      "name": "Passkeys Demo",
      "id": "passkeys-demo.appspot.com"
    },
    "timeout": 60000,
    "user": { "name": "user", "displayName": "user", "id": {} }
  },
  "signal": {},
  "mediation": "conditional"
}
```

And here is the JSON of the the options used by `wax_demo`:

```json
{
  "publicKey": {
    "challenge": {},
    "rp": { "id": "localhost", "name": "Wax FTW" },
    "user": { "id": {}, "name": "user", "displayName": "user" },
    "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
    "attestation": "none",
    "authenticatorSelection": { "residentKey": "preferred" }
  }
}
```

### Attestation issues

I'm trying to get things working with both Enpass and a USB security key device.
There are two issues: 

  1. obtaining the aaguid from a hardware security key
  2. matching the returned attestation value to the requested conveyance

The results from testing passkey credential creation with different values for the `:attestation` option:

| Attestation | Enpass | USB Security Key |
| ----------- | ------ | ---------------- |
| none (default) | **OK, with aaguid** | OK, no aaguid returned |
| direct | ERROR verifying format `:none` | **OK, with aaguid** |
| indirect | ERROR verifying format `:none` | ERROR verifying format `:packed` |

The ERROR is a `Wax.AttestationVerificationError` with reason `:invalid_attestation_conveyance_preference`.

Until this is solved, I am using two different buttons in the UI to specify the
attestation value used when creating passkeys.

### Enpass "Update Item" vs "Save as New"

For Enpass, and maybe other authenticators, passkey credentials are stored inside named "items", that can be edited within Enpass and can contain additional data. When you create a new credential, the password manager gives you the option of adding the new credential to an existing item that contains a passkey with the same rp_id, or saving the new credential in a new item. Either way, the credential id returned to the Elixir application is new.

### Removing a passkey

(TODO) We can add a Remove button on the account settings page to delete the associated `UserCredential` record, but as far as I know there is no method in the `CredentialsContainer` interface that will allow removing the credential from Enpass (or a Yubikey). You can also delete the entire item in the Enpass application (thereby destroying the passkey), but I don't find a way to remove a passkey from an Enpass item leaving the other information intact (username and password for example).

### Logging in with a passkey (via Enpass)

Running at a HTTPS url, the passkey registration flow correctly brings up a dialog for the Enpass password manager when using Chrome or Firefox with the Enpass extension enabled. If you cancel the Enpass registration, the browser will present the "Passkeys & Security Keys" dialog in Chrome allowing either a physical device or a QR code for a mobile device. In Firefox, you will see a dialog that says "Touch your security key to continue with localhost".

In the passkey authentication flow the Enpass dialog says "Verification required to sign in with passkey". If verified, the Enpass dialog says "Signing in using passkey" with a "Sign In" button.

In Firefox, various errors were encountered when verifying in Enpass and/or when the "Sign In" button is pressed:

- "Illegal invocation"

I have also seen this error, when canceling out of Enpass:

- "Your device can't be used with this site. ...ngrok-free.app may require a newer or different kind of device."

### Non fido-approved metadata

The `wax_` library will fail to authenticate with the error "Authenticator metadata was not found" if the authenticator's aaguid was not loaded from the "MDS3 Blob" of the official [FIDO Alliance Metadata Service](https://fidoalliance.org/metadata/). You can see which aaguids are included by using the [FIDO MDS Explorer](https://opotonniee.github.io/fido-mds-explorer/)

Out of the box, `Wax.Metadata.get_by_aaguid` does not succeed with the Enpass manager's aaguid, "f3809540-7f14-49c1-a8b3-8f813b225541" (or the raw binary `<<243, 128, 149, 64, 127, 20, 73, 193, 168, 179, 143, 129, 59, 34, 85, 65>>`).

However `wax_` will load non FIDO-approved metadata in any .json file placed in the priv/fido2_metadata directory.

aaguids and icons for Enpass and other password managers are listed in this file: https://github.com/passkeydeveloper/passkey-authenticator-aaguids/blob/main/aaguid.json and can be converted to the FIDO metadata format that `wax_` expects. 

The metadata statement keys that seem to be used by `wax_`:

- `description` (the display name for the authenticator)
- `icon` (a `data:image:` URL, typically png or svg)
- `attestationTypes` (usually "basic_full")
- `attestationRootCertificates` (Base64 encoded)
- `keyProtection` (only used in comments for `Wax.new_registration_challenge`). Can be `["hardware", "secure_element"]`

Using data from the passkey-authenticator-aaguids repository, I have added the following:

- 1password.json
- bitwarden.json
- dashlane.json
- enpass.json
- thetis_pro.json

Also included by copying from the `wax_demo` repository:

- chrome_virtual_authenticator.json
- yubikey_neo.json
