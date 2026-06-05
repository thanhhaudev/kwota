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

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "System")
                    AboutSystemCard(snapshot: snapshot)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Links")
                    AboutLinksCard()
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
}
