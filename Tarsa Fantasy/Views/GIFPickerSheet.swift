import SwiftUI

// GIF search grid. Mirrors FindPeopleSheet's debounced-search pattern; on
// tap it hands the chosen GIF's full URL back to the composer, which sends
// it as an image-only message. Shows trending GIFs until the user types.
struct GIFPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var results: [GIFResult] = []
    @State private var isLoading = false
    @State private var didInitialLoad = false
    @State private var searchTask: Task<Void, Never>? = nil

    private let columns = [
        GridItem(.flexible(), spacing: FFSpace.s),
        GridItem(.flexible(), spacing: FFSpace.s),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if GiphyConfig.isConfigured {
                    VStack(spacing: FFSpace.m) {
                        searchField
                        content
                    }
                    .padding(FFSpace.l)
                } else {
                    unavailable
                }
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            .task {
                guard !didInitialLoad, GiphyConfig.isConfigured else { return }
                didInitialLoad = true
                isLoading = true
                results = await GIFService.shared.featured()
                isLoading = false
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: FFSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
            TextField("", text: $query, prompt:
                Text("Search GIPHY").foregroundColor(FFColor.textTertiary)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.ffBody)
            .foregroundStyle(FFColor.textPrimary)
            .onChange(of: query) { _, new in scheduleSearch(new) }
            if !query.isEmpty {
                Button {
                    query = ""
                    scheduleSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FFColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && results.isEmpty {
            ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xl)
            Spacer()
        } else if results.isEmpty {
            empty
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: FFSpace.s) {
                    ForEach(results) { gif in
                        gifCell(gif)
                    }
                }
                .padding(.bottom, FFSpace.l)
            }
            attribution
        }
    }

    @ViewBuilder
    private func gifCell(_ gif: GIFResult) -> some View {
        if let url = URL(string: gif.previewURL) {
            Button {
                onPick(gif.fullURL)
            } label: {
                AnimatedImageView(url: url)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .background(FFColor.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.s)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var attribution: some View {
        Text("Powered by GIPHY")
            .font(.ffMicro)
            .foregroundStyle(FFColor.textTertiary)
            .padding(.bottom, FFSpace.xs)
    }

    private var empty: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No GIFs found.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.xxl)
    }

    private var unavailable: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("GIF search isn't set up yet")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text("Add a GIPHY API key in GIFService.swift to enable GIF search.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, FFSpace.xxl)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            isLoading = true
            let found = trimmed.isEmpty
                ? await GIFService.shared.featured()
                : await GIFService.shared.search(query: trimmed)
            if Task.isCancelled { return }
            results = found
            isLoading = false
        }
    }
}
