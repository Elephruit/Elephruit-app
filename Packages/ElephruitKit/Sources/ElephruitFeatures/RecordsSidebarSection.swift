import ElephruitDesign
import SwiftUI

struct RecordsSidebarSection: View {
    let navigation: NavigationModel

    @ScaledMetric(relativeTo: .body) private var rowHeight = SidebarMetrics.baseRowHeight

    var body: some View {
        Section("Records") {
            row(.all)
            row(.unsorted)
        }

        Section("Types") {
            row(.people)
            row(.pets)
            row(.vehicles)
            row(.organizations)
            row(.other)
        }
    }

    private func row(_ scope: RecordsScope) -> some View {
        let selected = navigation.selection == .records(scope)
        return Label(scope.title, systemImage: scope.symbolName)
            .frame(minHeight: rowHeight)
            .tag(SidebarSelection.records(scope))
            .accessibilityIdentifier("sidebar.records.\(scope.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
