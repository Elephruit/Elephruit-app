import ElephruitDesign
import Foundation
import MapKit
import SwiftUI

struct MapPlaceListing: Identifiable, Hashable, Sendable {
    let id: String
    let mapItemIdentifier: String?
    let name: String
    let address: String
    let phone: String
    let website: String
    let mapsURL: String
    let latitude: String
    let longitude: String

    @MainActor
    init(mapItem: MKMapItem) {
        let coordinate = mapItem.location.coordinate
        let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = mapItem.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = mapItem.identifier?.rawValue

        self.mapItemIdentifier = identifier
        self.name = name
        self.address = address
        self.phone = mapItem.phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.website = mapItem.url?.absoluteString ?? ""
        self.latitude = String(coordinate.latitude)
        self.longitude = String(coordinate.longitude)
        self.mapsURL = Self.mapsURL(name: name, coordinate: coordinate)
        self.id = identifier ?? "\(name)|\(address)|\(coordinate.latitude),\(coordinate.longitude)"
    }

    private static func mapsURL(name: String, coordinate: CLLocationCoordinate2D) -> String {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
        ]
        return components?.url?.absoluteString ?? ""
    }
}

@MainActor
@Observable
private final class MapPlaceSearchModel {
    var results: [MapPlaceListing] = []
    var isSearching = false
    var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    func search(for rawQuery: String) {
        searchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            results = []
            isSearching = false
            errorMessage = nil
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }

            isSearching = true
            errorMessage = nil
            defer { isSearching = false }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                results = Array(response.mapItems.prefix(6)).map(MapPlaceListing.init)
            } catch where Task.isCancelled {
                return
            } catch {
                results = []
                errorMessage = "Apple Maps search is unavailable right now. You can still type this manually."
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        results = []
        isSearching = false
        errorMessage = nil
    }
}

struct MapPlaceSearchField: View {
    let label: String
    @Binding var text: String
    let onSelect: (MapPlaceListing) -> Void
    let onClear: () -> Void

    @State private var model = MapPlaceSearchModel()
    @State private var selectedListing: MapPlaceListing?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.large) {
                Text(label)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 150, alignment: .leading)

                TextField(label, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)

                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "map")
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .help("Search Apple Maps")
                }
            }
            .frame(minHeight: 54)

            if let selectedListing {
                selectedSummary(selectedListing)
            } else if isFocused && !model.results.isEmpty {
                searchResults
            } else if isFocused, let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .padding(.leading, 174)
                    .padding(.bottom, Theme.Spacing.medium)
            }
        }
        .onChange(of: text) { _, newValue in
            if newValue != selectedListing?.name {
                if selectedListing != nil { onClear() }
                selectedListing = nil
                model.search(for: newValue)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectedListing == nil { model.search(for: text) }
            if !focused, selectedListing == nil { model.clear() }
        }
    }

    private var searchResults: some View {
        VStack(spacing: Theme.Spacing.hairline) {
            ForEach(model.results) { listing in
                Button {
                    selectedListing = listing
                    text = listing.name
                    model.clear()
                    onSelect(listing)
                } label: {
                    HStack(spacing: Theme.Spacing.medium) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Theme.Colors.selection)
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text(listing.name)
                                .font(Theme.Text.rowTitleEmphasised)
                                .foregroundStyle(Theme.Colors.primaryText)
                            if !listing.address.isEmpty {
                                Text(listing.address)
                                    .font(Theme.Text.rowSubtitle)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.small)
        .marginLeadingForEditorField()
        .background(Theme.Colors.contentBackground)
        .clipShape(.rect(cornerRadius: Theme.Radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(Theme.Colors.separator.opacity(0.7))
        }
        .padding(.bottom, Theme.Spacing.medium)
    }

    private func selectedSummary(_ listing: MapPlaceListing) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.selection)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Linked to Apple Maps")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                if !listing.address.isEmpty {
                    Text(listing.address)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
        }
        .marginLeadingForEditorField()
        .padding(.bottom, Theme.Spacing.medium)
    }
}

private extension View {
    func marginLeadingForEditorField() -> some View {
        padding(.leading, 174)
    }
}
