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

The Phoenix LiveView app was created with `mix phx.new` and `mix phx.gen.auth`, 
and uses the [`Wax` library](https://github.com/tanguilp/wax). The logic for 
creating and authenticating passkeys was adapted from the 
[`wax_demo` application](https://github.com/tanguilp/wax_demo), but uses LiveView, 
instead of controlllers, communicating between backend and frontend with 
LiveView's `push_event/4` function and LiveView hook's Javascript `pushEvent` method.

Passkeys are created on the "Passkeys" live view page, and authenticated on the "Login" 
live view.

Passkey data (authenticator aaguid, public key, sign count) are stored in the 
Ecto `UserCredential` schema, which references the `User`.

I also consulted the source code for Google's 
[`passkeys-demo` node-based application](https://github.com/GoogleChromeLabs/passkeys-demo) 
for other information. A live sandbox of the `passkeys-demo` code is available 
at https://passkeys-demo.appspot.com 

`passkeys-demo` uses the Javascript PublicKeyCredential API and the 
[`simplewebauthn` node package](https://simplewebauthn.dev/docs/packages/server)

For testing, I am using the Enpass password manager installed with its Google 
Chrome and Firefox browser extensions.

In order to work with the Enpass extension, the server must be hosted on an SSL 
domain, not localhost. On localhost you will see only the "Passkeys & Security Keys" 
dialog in Chrome, or a dialog that says "Touch your security key to continue 
with localhost" in Firefox, allowing you to use a Yubikey or other authenticator device.

 I have used [ngrok free](https://ngrok.com/) to create a tunnel betweent the 
 localhost dev server and an HTTPS url.

The `:wax_` OTP application configuration must be set to the correct origin in 
this setup.  The configuration specifies `rp_id: :auto` and will parse the passkey 
RP domain from whatever is specified in its `:origin` configuration. I use the 
environment variable `WAX_ORIGIN` to override the default setting of 
`origin: http://localhost:4000` (where the Phoenix LiveView dev server normally runs).

If you don't set the origin correctly you will get a failure message:

"The relying party ID is not a registrable domain suffix of, nor equal to the 
current domain. Subsequently, the .well-known/webauthn resource of the claimed 
RP ID had the wrong content-type. (It should be application/json.)".

### Registering a new passkey

Passkey registration can be offered:

1. At the end of a new account registration process, or
2. At the end of a log in process, after you have already authenticated (logged in) 
  by other means (magic link or password)
3. From the passkeys page, after you have authenticated by other means

#### Attestation issues

The application has been tested with both Enpass and a USB security key device.
There are two issues: 

  1. obtaining the aaguid from a hardware security key
  2. matching the returned attestation value to the requested conveyance

Using Wax 0.8 (actually the 
`tl/remove_attestation_conveyance_preference_check_in_atetstation_statement_impls` branch
that will be merged into version 0.8), I tried different values for the `attestation` 
option of `PublicKeyCredentialCreationOptions` when calling `navigator.credentials.create`:

| Attestation | Enpass | USB Security Key |
| ----------- | ------ | ---------------- |
| direct | **OK, with aaguid** | **OK, with aaguid** |
| indirect | **OK, with aaguid** | OK, no aaguid returned |

So "direct" seems to work best for retrieving aaguids. 

Note: if you do not get the aaguid from the response, you can possibly identify 
at least the generic type of the authenticator from the 
`credential.authenticatorAttachment` and `credential.response.getTransports()` 
data. This information is now displayed to the user. In addition I pull the 
`credProps` extension  information to ascertain and present whether the credential 
has a resident key (aka is "discoverable").

| Authenticator | Attachment | Transports | Resident Key |
| ------------- | ---------- | ---------- | ------------ |
| Enpass | cross-platform | internal | true |
| USB security key | cross-platform | nfc, usb | true |
| Built-in device | platform? | internal? | varies? |

#### Client capabilities

On my Linux machine this is what I get from `PublicKeyCredential.getClientCapabilities()`:

| Capability | Chrome (no extension) | Chrome with Enpass |
| ---------- | --------------------- | ------------------ |
| conditionalCreate | **true** | false |
| conditionalGet | **true** | false |
| hybridTransport | **true** | **true** |
| passkeyPlatformAuthenticator | **true** | **true** |
| relatedOrigins | **true** | false |
| signalAllAcceptedCredentials | **true** | false |
| signalCurrentUserDetails | **true** | false |
| signalUnknownCredential | **true** | false |
| userVerifyingPlatformAuthenticator | **true** | **true** |
| extension:appid | **true** | missing |
| extension:appidExclude | **true** | missing |
| extension:credBlob | **true** | missing |
| extension:credentialProtectionPolicy | **true** | missing |
| extension:credProps | **true** | **true** |
| extension:enforceCredentialProtectionPolicy | **true** | missing |
| extension:getCredBlob | **true** | missing |
| extension:hmacCreateSecret | **true** | missing |
| extension:largeBlob | **true** | missing |
| extension:minPinLength | **true** | missing |
| extension:payment | false | missing |
| extension:prf | **true** | **true** |

Ideally, a capability like `signalAllAcceptedCredentials` could be used to manage
syncing between the RP database of current passkeys and the related authenticator.

#### Options for navigator.credentials.create

Here are the options sent by `passkeys-demo`:

```javascript
{
  publicKey: {
    attestation: "none",
    authenticatorSelection: {
      authenticatorAttachment: "platform",
      requireResidentKey: true
    },
    challenge: {},
    excludeCredentials: [],
    extensions: {
      credProps: true,
      enforceCredentialProtectionPolicy: false
    },
    hints: [],
    pubKeyCredParams: [
      { alg: -8, type: "public-key" },
      { alg: -7, type: "public-key" },
      { alg: -257, type: "public-key" }
    ],
    rp: {
      id: "passkeys-demo.appspot.com",
      name: "Passkeys Demo"
    },
    timeout: 60000,
    user: { name: "user", displayName: "user", id: {} }
  },
  signal: {},
  mediation: "conditional"
}
```

And here are the options used by `wax_demo`:

```javascript
{
  publicKey: {
    attestation: "none",
    authenticatorSelection: { 
      residentKey: "preferred" 
    },
    challenge: {},
    pubKeyCredParams: [
      { alg: -7, type: "public-key" }
    ],
    rp: { 
      id: "localhost", 
      name: "Wax FTW" 
    },
    user: { 
      id: {}, 
      name: "user", 
      displayName: "user" 
    }
  }
}
```

For the `Wax.Challenge` object, the configuration options we use 
in dev.exs are:

```elixir
[
  origin: System.get_env("WAX_ORIGIN", "http://localhost:4000"),
  rp_id: :auto,
  allowed_attestation_types: [:basic, :uncertain, :attca, :self]
]
```

And besides the `challenge`, `rp`, and `user`, the options we are using for 
`navigator.credentials.create` are:

```javascript
{
  attestation: "direct",
  authenticatorSelection: {
    residentKey: "required",
    requireResidentKey: true,
  },
  extensions: {
    credProps: true
  },
  pubKeyCredParams: [
    { alg: -8, type: "public-key"},
    { alg: -7, type: "public-key"},
    { alg: -257, type: "public-key"}
  ]
}
```

### Enpass "Update Item" vs "Save as New"

For Enpass, and maybe other authenticators, passkey credentials are stored 
inside named "items", that can be edited within Enpass and can contain additional 
data. When you create a new credential, the password manager gives you the option 
of adding the new credential to an existing item that contains a passkey with 
the same `rp_id`, or saving the new credential in a new item. Either way, the 
credential id returned to the Elixir application is new.

### Removing a passkey

A Remove button on the passkeys page to delete the associated `UserCredential` 
record, but as far as I know there is no method in the `CredentialsContainer` 
interface that will allow removing the credential from Enpass (or a Yubikey).
You can also delete the entire item in the Enpass application (thereby destroying 
the passkey), but I don't find a way to remove a passkey from an Enpass item 
leaving the other information intact (username and password for example).

If `true`, the boolean configuration setting `:prune_stale_credentials` will
delete all previous passkeys with matching `aaguid`, `rp_id` and `user_id`
when a new passkey is inserted. This does not solve the use case where a user may
have multiple USB security keys with the same `aaguid`...

### Logging in with a passkey (via Enpass)

Running at a HTTPS url, the passkey registration flow correctly brings up a dialog 
for the Enpass password manager when using Chrome or Firefox with the Enpass 
extension enabled. If you cancel the Enpass registration, the browser will present 
the "Passkeys & Security Keys" dialog in Chrome allowing either a physical device 
or a QR code for a mobile device. In Firefox, you will see a dialog that says 
"Touch your security key to continue with localhost".

In the passkey authentication flow the Enpass dialog says "Verification required 
to sign in with passkey". If verified, the Enpass dialog says "Signing in using 
passkey" with a "Sign In" button.

In Firefox, various errors were encountered when verifying in Enpass and/or when 
the "Sign In" button is pressed:

- "Illegal invocation"

I have also seen this error, when canceling out of Enpass:

- "Your device can't be used with this site. ...ngrok-free.app may require a 
  newer or different kind of device."

### Non FIDO-approved metadata

The `Wax` library will fail to authenticate with the error "Authenticator 
metadata was not found" if the authenticator's aaguid was not loaded from the 
"MDS3 Blob" of the official [FIDO Alliance Metadata Service](https://fidoalliance.org/metadata/). 
You can see which aaguids are included by using the 
[FIDO MDS Explorer](https://opotonniee.github.io/fido-mds-explorer/)

Out of the box, `Wax.Metadata.get_by_aaguid` does not succeed with the Enpass 
manager's aaguid, "f3809540-7f14-49c1-a8b3-8f813b225541" (or the raw binary 
`<<243, 128, 149, 64, 127, 20, 73, 193, 168, 179, 143, 129, 59, 34, 85, 65>>`).

However `Wax` will load non FIDO-approved metadata in any .json file placed in 
the priv/fido2_metadata directory.

aaguids and icons for Enpass and other password managers are listed in this file: 
https://github.com/passkeydeveloper/passkey-authenticator-aaguids/blob/main/aaguid.json 
and can be converted to the FIDO metadata format that `Wax` expects. 

The metadata statement keys that seem to be used by `Wax`:

- `description` (the display name for the authenticator)
- `icon` (a `data:image:` URL, typically png or svg)
- `attestationTypes` (usually "basic_full")
- `attestationRootCertificates` (Base64 encoded)
- `keyProtection` (only used in comments for `Wax.new_registration_challenge`). 
  Can be `["hardware", "secure_element"]`

Using data from the passkey-authenticator-aaguids repository, I have added 
the following:

- 1password.json
- bitwarden.json
- dashlane.json
- enpass.json
- thetis_pro.json

Also included by copying from the `wax_demo` repository:

- chrome_virtual_authenticator.json
- yubikey_neo.json
