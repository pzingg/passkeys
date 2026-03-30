# Passkeys

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

## Registering a new passkey

Passkey registration can be offered:

1. At the end of a new account registration process, or
2. At the end of a log in process, after you have already authenticated (logged in) by other means (magic link or password)
3. From the account settings page, after you have authenticated by other means

Compare Google's passkeys-demo application with Wax's wax-demo application.
passkeys-demo uses the PublicKeyCredential API and the node package https://simplewebauthn.dev/docs/packages/server

passkeys-demo correctly brings up Enpass password manager when using Chrome or Firefox with the Enpass extension enabled. If you cancel the Enpass registration, the "Passkeys & Security Keys" dialog appears in Chrome.

wax-demo in Chrome with the Enpass extension enabled, brings up a "Passkeys & Security Keys" dialog offering a QR code to scan. in Firefox 148/Linx, the page says, "\[username\], press your authenticator now!", and a dialog pops up that says "Touch your security key to continue with localhost".

### params for navigator.credentials.create

The JSON below is what is sent by Google's passkeys-demo.

It only works on ngrok, on localhost, you get "The relying party ID is not a registrable domain suffix of, nor equal to the current domain. Subsequently, the .well-known/webauthn resource of the claimed RP ID had the wrong content-type. (It should be application/json.)".

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
      "id": "2e51-2601-645-d81-dd60-5613-79ff-fe93-6d2d.ngrok-free.app"
    },
    "timeout": 60000,
    "user": { "name": "cowper", "displayName": "cowper", "id": {} }
  },
  "signal": {},
  "mediation": "conditional"
}
```

This is the JSON from wax_demo:

```json
{
  "publicKey": {
    "challenge": {},
    "rp": { "id": "localhost", "name": "Wax FTW" },
    "user": { "id": {}, "name": "cowper", "displayName": "cowper" },
    "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
    "attestation": "none",
    "authenticatorSelection": { "residentKey": "preferred" }
  }
}
```

If you cancel out of the Enpass you get "Your device can't be used with this site. ...ngrok-free.app may require a newer or different kind of device."

## Removing a passkey

Generally done via the account settings page.

## Logging in with a passkey (via Enpass)

After creating a passkey with the passkeys-demo app, the one-button login in Chrome with Enpass extension enabled brings up Enpass dialog "Verification required to sign in with passkey". If verified, the Enpass dialg says "Signing in using passkey" with a "Sign In" button. If you cancel in Firefox, a dialog appears that says "Touch your security key to continue with passkeys-demo-appspot.com".

But when verified in Enpass or the "Sign In" button is pressed, the error dialog "Illegal invocation" appears. On Firefox with Enpass extension enabled, the error is "'toJSON' called on an object that does not implement interface PublicKeyCredential."

With the wax_demo, passkey log in does bring up the Enpass verification dialog (but only using ngrok SSL origin, not localhost), but `Wax.authenticate` fails in `CredentialController.validate` with the flash message "Authentication failed (error: Authenticator metadata was not found)".

`Wax.Metadata.get_by_aaguid` does not have the Enpass manager, 
guid `<<243, 128, 149, 64, 127, 20, 73, 193, 168, 179, 143, 129, 59, 34, 85, 65>>`

The metadata statement values used by Wax and WaxDemo are:

- `description`
- `icon` (a `data:image:png;base64` URL)
- `attestationTypes` (usually "basic_full")
- `attestationRootCertificates` (Base64 encoded)
- `keyProtection` (only used in comments for `Wax.new_registration_challenge`). Can be `["hardware", "secure_element"]`

Enpass is listed in this file https://github.com/passkeydeveloper/passkey-authenticator-aaguids
