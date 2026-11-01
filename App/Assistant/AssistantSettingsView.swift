import SwiftUI

@MainActor
struct AssistantSettingsView: View {
    @ObservedObject var settings: AssistantSettings
    @ObservedObject var engine: AssistantEngine
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [ElevenLabsVoice.Voice] = []
    @State private var voicesMessage: String?
    @State private var isLoadingVoices = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anthropic API anahtarı (sk-ant-…)", text: $settings.anthropicAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Model", selection: $settings.model) {
                        ForEach(AssistantModel.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    LabeledContent("Durum", value: settings.isAIConfigured ? "Hazır" : "Anahtar gerekli")
                } header: {
                    Text("Yapay zekâ (Claude)")
                } footer: {
                    Text("Anahtar yalnızca bu cihazın anahtar zincirinde saklanır ve doğrudan Anthropic'e gönderilir. console.anthropic.com adresinden alabilirsiniz.")
                }

                Section {
                    Picker("Sağlayıcı", selection: $settings.voiceProvider) {
                        ForEach(VoiceProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    if settings.voiceProvider == .elevenLabs {
                        SecureField("ElevenLabs API anahtarı", text: $settings.elevenLabsAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Ses kimliği (voice ID)", text: $settings.elevenLabsVoiceID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(isLoadingVoices ? "Sesler getiriliyor…" : "Hesabımdaki sesleri getir") {
                            loadVoices()
                        }
                        .disabled(isLoadingVoices || settings.effectiveElevenLabsAPIKey.isEmpty)
                        if let voicesMessage {
                            Text(voicesMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(voices) { voice in
                            Button {
                                settings.elevenLabsVoiceID = voice.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(voice.name)
                                        if !voice.description.isEmpty {
                                            Text(voice.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if settings.elevenLabsVoiceID == voice.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    Button("Sesi dene") {
                        engine.speakSample()
                    }
                } header: {
                    Text("Ses")
                } footer: {
                    Text("Apple sesi ücretsizdir ve çevrimdışı çalışır. ElevenLabs daha doğal konuşur; anahtar ve ses kimliği girilmemişse Apple sesi kullanılır.")
                }

                Section {
                    TextField("Asistanın adı", text: $settings.assistantName)
                    TextField("Hitap (efendim, patron, kaptan…)", text: $settings.honorific)
                    TextField("Adınız (isteğe bağlı)", text: $settings.userName)
                } header: {
                    Text("Kişilik")
                } footer: {
                    Text("Karakter: Alfred'in zarafeti, usta bir barmenin rahatlığı.")
                }

                Section {
                    Toggle("Uygulama açılınca asistan ekranı", isOn: $settings.startsAtLaunch)
                    Toggle("Cevaptan sonra dinlemeye devam et", isOn: $settings.autoListen)
                } header: {
                    Text("Davranış")
                }

                Section {
                    Button("Sohbeti sıfırla", role: .destructive) {
                        engine.reset()
                    }
                }
            }
            .navigationTitle("Asistan ayarları")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
    }

    private func loadVoices() {
        isLoadingVoices = true
        voicesMessage = nil
        let apiKey = settings.effectiveElevenLabsAPIKey
        Task {
            do {
                let fetched = try await ElevenLabsVoice.listVoices(apiKey: apiKey)
                voices = fetched
                voicesMessage = fetched.isEmpty ? "Hesapta ses bulunamadı." : "Bir ses seçin."
            } catch {
                voicesMessage = error.localizedDescription
            }
            isLoadingVoices = false
        }
    }
}
