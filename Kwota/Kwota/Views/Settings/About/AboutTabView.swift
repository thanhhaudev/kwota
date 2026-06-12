//
//  AboutTabView.swift
//  Kwota
//

import SwiftUI

struct AboutTabView: View {
    let vm: MenuBarViewModel

    @State private var snapshot: SystemSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AboutHeroCard(snapshot: snapshot)

                // The one place that explains why the privileged-helper
                // surfaces are absent on an ad-hoc build (they're hidden,
                // not broken, everywhere else).
                if !vm.privilegedHelper.isSupported {
                    adHocBuildNote
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "System")
                    AboutSystemCard(snapshot: snapshot)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: ObjectIdentifier(vm.registry)) {
            snapshot = await SystemInfoProvider.snapshot(registry: vm.registry)
        }
    }

    private var adHocBuildNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ad-hoc build")
                    .font(.system(size: 13, weight: .semibold))
                Text("This copy of Kwota isn't signed with a Developer ID. System-cache cleaning is unavailable; everything else works normally.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .settingsCard()
    }
}
