# Connecting to a Windows host

English | [简体中文](../zh-CN/remote-processing.md) · [Home](../../README.md)

A Windows computer can share local Whisper and text models with another Windows computer or an Android phone. The client handles capture, captions, and transcript storage; the host handles recognition, translation, and summaries.

## Pairing a device

1. Prepare Whisper and a model on the host. For translation or summaries, start and configure Ollama or a local OpenAI-compatible text service.
2. On the host's **Devices** page, turn on sharing: choose a network address, port (8178 by default), model, and CPU or GPU, optionally share the text service, then start. A shared text service offers every model it lists; the host's own choice is the default. The panel then shows a QR code and a six-digit pairing code; **Add device** on the same page reopens it later.
3. On an Android phone, open **Devices → Scan to pair** and point the camera at the QR code. On a Windows client, or without a camera, choose **Connect to host**: hosts sharing on the same network are listed under *Hosts nearby*, so pick one or type the address, then enter the pairing code. An invite link copied from the host's panel can be pasted into the address field instead.
4. The host becomes the processing engine right away. Return to the home screen and start live or file transcription. While a host is connected, **Settings → Translation & LLM** offers a choice between the host's shared text service (the default, with any of the models it lists) and a service of your own, such as OpenAI or an online OpenAI-compatible service. If the host shares no text model, pick your own service there or turn off translation, title/summary generation, and file cleanup.
5. To return to local or cloud processing, save a different engine under **Settings → Whisper models**.

A pairing code lasts ten minutes and works once; closing the host's sharing panel ends it, and **New code** makes another. Each paired device receives its own credential, which stays valid across restarts of sharing until the device is removed from the host's *Paired devices* list. Hosts running 0.6.1 or older have no pairing codes; they still accept the token they display.

The client does not need Whisper or model weights. Windows file transcription still requires local FFmpeg; Android includes decoding components.

## Status and discovery

- The **Devices** page shows whether the saved host is online, busy, or offline, checked every twenty seconds while the page is open. The host shows when each paired device was last seen.
- Hosts answer discovery requests on UDP port 47653 from devices on the same network. If the saved host later answers from a different address, for example after a DHCP change, the client updates the address by itself, but only after the host there has proved it holds this device's credential: the client sends a random challenge and expects a keyed hash over the challenge and the address the client dialled, which only the real host listening at that address can compute. A device that merely passes the challenge on to the real host is refused, so the credential is never sent to an unverified address. Every connection of a paired device runs this check, so connect to the address the host shows: an address that only forwards to the host, such as a forwarded port, fails it. Discovery does not cross networks; over Tailscale, connect by address.
- Windows Firewall must allow the app's inbound connections: the sharing port over TCP and port 47653 over UDP. Windows normally asks once when sharing first starts; the app does not change firewall rules.

## Sharing and networking

- Sharing is off by default. Closing its settings panel leaves sharing active; turn off the sharing switch or exit the host app to end it.
- Local network addresses and Tailscale's private address range are accepted. Connections between Tailscale nodes have not been verified. Public internet connections and HTTPS are not supported.
- HTTP does not encrypt traffic; share only on trusted networks. Tailscale connections rely on Tailscale's own network protection.
- Running local transcription and sharing at the same time uses additional memory or GPU memory. Clients receive a message when the host is busy.

## Data and interruptions

Transcripts are stored on the client. The host does not store client transcripts or raw recordings. Imported files are read on the client and sent as audio segments rather than copied in full to the host. The host shares only local models and does not proxy cloud services.

Pausing stops new capture. Discarding cancels the current task and deletes its client transcript without shutting down the host. Ending host sharing interrupts client tasks. A disconnect preserves completed text; translation failures preserve the source text.

Automatic reconnection, audio resumption, task migration, and transcript synchronization are not available. The client saves one host, with an encrypted credential. The host keeps only a hash of each device's credential, in `devices.json` next to its settings, so the file cannot be used to connect.
