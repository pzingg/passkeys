// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/passkeys"
import topbar from "../vendor/topbar"

function _arrayBufferToString(buffer) {
  var binary = '';
  var bytes = new Uint8Array(buffer);
  var len = bytes.byteLength;
  for (var i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[ i ]);
  }
  return binary;
}

function _arrayBufferToBase64(buffer) {
  var binary = '';
  var bytes = new Uint8Array(buffer);
  var len = bytes.byteLength;
  for (var i = 0; i < len; i++) {
    binary += String.fromCharCode(bytes[ i ]);
  }
  return window.btoa( binary );
}

function _base64ToArrayBuffer(base64) {
  var binary_string =  window.atob(base64);
  var len = binary_string.length;
  var bytes = new Uint8Array(len);
  for (var i = 0; i < len; i++)        {
      bytes[i] = binary_string.charCodeAt(i);
  }
  return bytes.buffer;
}

function _stringToArrayBuffer(str) {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(str);
  return bytes.buffer;
}

let Hooks = {}
Hooks.register_passkey = {
  mounted() {
    this.handleEvent("trigger-attestation", ({rp_id, rp_name, challenge, attestation, user_id, user_email}) => {
      const params = {
        publicKey: {
          challenge: _base64ToArrayBuffer(challenge),
          rp: {
            id: rp_id,
            name: rp_name
          },
          user: {
            id: _stringToArrayBuffer(user_id),
            name: user_email,
            displayName: user_email
          },
          pubKeyCredParams: [
            {
              type: "public-key", alg: -7 // "ES256" IANA COSE Algorithms registry
            }
          ],
        attestation: attestation,
          authenticatorSelection: {
            residentKey: 'preferred'
          }
        }
      }

      const paramsString = JSON.stringify(params);
      console.log(`credentials.create ${paramsString}`);

      const that = this;
      navigator.credentials.create(params)
        .then(function (newCredential) {
          that.pushEvent("credential_created", {
            type: newCredential.type,
            raw_id: _arrayBufferToBase64(newCredential.rawId),
            client_data_json: _arrayBufferToString(newCredential.response.clientDataJSON),
            attestation_object: _arrayBufferToBase64(newCredential.response.attestationObject)
          });
        })
        .catch(function (err) {
          console.error(err);
          that.pushEvent("credentials_create_failed", {error: err.message});
        });
    });
  }
};

Hooks.authenticate_passkey = {
  mounted() {
    this.handleEvent("trigger-authentication", ({challenge, cred_ids}) => {
      const allowCredentials = cred_ids.map((cred_id) => {
        return {id: _base64ToArrayBuffer(cred_id), type: "public-key"};
      });

      // userHandle is an ArrayBuffer containing an opaque user identifier, specified as user.id
      // in the options passed to the originating navigator.credentials.create() call.

      const that = this;
      navigator.credentials.get({
        publicKey: {
          challenge: _base64ToArrayBuffer(challenge),
          allowCredentials: allowCredentials,
        }
      }).then(function (newCredential) {
        that.pushEvent("credential_selected", {
            type: newCredential.type,
            raw_id: _arrayBufferToBase64(newCredential.rawId),
            client_data_json: _arrayBufferToString(newCredential.response.clientDataJSON),
            authenticator_data: _arrayBufferToBase64(newCredential.response.authenticatorData),
            signature: _arrayBufferToBase64(newCredential.response.signature),
            user_handle: _arrayBufferToString(newCredential.response.userHandle)
          });
        })
        .catch(function (err) {
          console.error(err);
          that.pushEvent("credentials_get_failed", {error: err.message});
        });
    });
  }
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks //, ...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

