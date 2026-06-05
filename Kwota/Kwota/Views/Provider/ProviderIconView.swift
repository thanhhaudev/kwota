//
//  ProviderIconView.swift
//  Kwota
//
//  Renders a provider's `iconAssetName` as an asset image when one is in the
//  catalog (e.g. "Mascot", "CodexLogo", "AntigravityLogo"), or as an SF Symbol
//  otherwise. Asset images stay tintable when their imageset is
//  template-rendered; the SF Symbol fallback keeps chrome resilient to
//  providers that ship without bundled artwork.
//

import SwiftUI
import AppKit

struct ProviderIconView: View {
    let assetName: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if NSImage(named: assetName) != nil {
                Image(assetName).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: assetName).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
    }
}
