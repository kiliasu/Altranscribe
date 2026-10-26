import Foundation

extension APIClient {
    /// Gemini's dedicated ASR uses Files + Interactions, not a generateContent prompt.
    /// Keep the Flutter implementation's upload validation and cancellation-safe cleanup.
    func transcribeGeminiFile(_ wave: Data, settings: AppSettings, key: String,
                              onWarning: @escaping @Sendable (AppError) -> Void) async throws -> String {
        let model = settings.effectiveGeminiSpeechModel
        guard !model.isEmpty, !model.contains("live"), !model.contains("/") else { throw AppError("Invalid model name.") }
        guard settings.vocabularyTerms.count <= 1000 else { throw AppError("Gemini accepts up to 1,000 vocabulary terms.") }
        let host = "https://generativelanguage.googleapis.com"
        var start = try request(endpoint: host, path: "upload/v1beta/files", key: key, auth: "google",
                                body: JSONSerialization.data(withJSONObject: ["file": ["display_name": "Altranscribe audio"]]))
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(wave.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        let (_, headers) = try await response(start)
        guard let location = headers.value(forHTTPHeaderField: "x-goog-upload-url"),
              let upload = URLComponents(string: location), upload.scheme == "https",
              upload.host?.lowercased() == "generativelanguage.googleapis.com",
              upload.user == nil, upload.password == nil, upload.fragment == nil,
              upload.port == nil || upload.port == 443, let url = upload.url else {
            throw AppError("The API returned an invalid response.")
        }
        var uploadRequest = try request(endpoint: host, path: "upload/v1beta/files", key: key, auth: "google",
                                        body: wave, contentType: "audio/wav")
        uploadRequest.url = url
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let uploaded = try await send(uploadRequest)
        guard var file = uploaded["file"] as? [String: Any], let name = file["name"] as? String,
              name.range(of: #"^files/[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw AppError("The API returned an invalid response.")
        }
        let text: String
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while file["state"] as? String == "PROCESSING" {
                guard ContinuousClock.now < deadline else { throw AppError("The uploaded audio did not finish processing.") }
                try await Task.sleep(for: .milliseconds(500))
                file = try await send(request(endpoint: settings.speechEndpoint, path: name, key: key, auth: "google", method: "GET"))
            }
            guard file["state"] as? String == "ACTIVE", let uri = file["uri"] as? String else {
                throw AppError("The uploaded audio did not finish processing.")
            }
            var transcription: [String: Any] = ["language_codes": settings.sourceLanguage == "auto" ? [] : [settings.geminiLanguage]]
            if !settings.vocabularyTerms.isEmpty { transcription["custom_vocabulary"] = settings.vocabularyTerms }
            let body: [String: Any] = ["model": model, "store": false, "input": [["type": "audio", "uri": uri, "mime_type": "audio/wav"]],
                                       "generation_config": ["transcription_config": transcription]]
            let result = try await send(request(endpoint: settings.speechEndpoint, path: "interactions", key: key, auth: "google",
                                                body: JSONSerialization.data(withJSONObject: body)))
            text = try Self.interactionText(result)
        } catch {
            await deleteGeminiUpload(name, key: key, onWarning: onWarning)
            throw error
        }
        await deleteGeminiUpload(name, key: key, onWarning: onWarning)
        return text
    }

    private func deleteGeminiUpload(_ name: String, key: String, onWarning: @escaping @Sendable (AppError) -> Void) async {
        // A detached cleanup task still runs after cancellation of the inference task.
        await Task.detached { [self] in
            do {
                var request = try request(endpoint: "https://generativelanguage.googleapis.com/v1beta", path: name,
                                          key: key, auth: "google", method: "DELETE")
                request.timeoutInterval = 10
                _ = try await response(request)
            } catch { onWarning(AppError("The transcript was retained, but the temporary Gemini upload could not be deleted.")) }
        }.value
    }
}
