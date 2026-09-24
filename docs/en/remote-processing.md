# Connecting to a Windows host

English | [简体中文](../zh-CN/remote-processing.md) · [Home](../../README.md)

A Windows computer can share local Whisper and text models with another Windows computer or an Android phone. The client handles capture, captions, and transcript storage; the host handles recognition, translation, and summaries.

## Connection steps

1. Prepare Whisper and a model on the host. For translation or summaries, start and configure Ollama or a local OpenAI-compatible text service.
2. Open sharing settings on the host's **Devices** page. Select a network address, port (8178 by default), model, and CPU or GPU. Optionally share the text model, then start sharing.
3. On the client, open **Devices → Connect to host**, enter the HTTP address and token shown by the host, and click **Connect and use**. The host becomes the processing engine right away.
4. Return to the home screen and start live or file transcription. If the host does not share a text model, turn off translation, title/summary generation, and file cleanup.
5. To return to local or cloud processing, save a different engine under **Settings → Whisper models**.

The client does not need Whisper or model weights. Windows file transcription still requires local FFmpeg; Android includes decoding components.

## Sharing and networking

- Sharing is off by default. Closing its settings panel leaves sharing active; turn off the sharing switch or exit the host app to end it.
- Each time sharing starts, a new token is generated. Clients must reconnect with the new token.
- Windows Firewall must allow inbound connections on the selected port. The app does not change firewall rules.
- Local network addresses and Tailscale's private address range are accepted. Connections between Tailscale nodes have not been verified. Public internet connections, HTTPS, and automatic device discovery are not supported.
- HTTP does not encrypt traffic; share only on trusted networks. Tailscale connections rely on Tailscale's own network protection.
- Running local transcription and sharing at the same time uses additional memory or GPU memory. Clients receive a message when the host is busy.

## Data and interruptions

Transcripts are stored on the client. The host does not store client transcripts or raw recordings. Imported files are read on the client and sent as audio segments rather than copied in full to the host. The host shares only local models and does not proxy cloud services.

Pausing stops new capture. Discarding cancels the current task and deletes its client transcript without shutting down the host. Ending host sharing interrupts client tasks. A disconnect preserves completed text; translation failures preserve the source text.

Automatic reconnection, audio resumption, task migration, and transcript synchronization are not available. The client saves one host configuration, with an encrypted token. Sharing does not support per-device permissions or individual device revocation.
