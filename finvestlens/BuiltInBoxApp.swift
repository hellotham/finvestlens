//
//  BuiltInBoxApp.swift
//  FinvestLens
//
//  FinvestLens's own Box app, as a build carries it.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FinvestLensUI

/// The client ID and secret of FinvestLens's own Box app, when this build
/// carries them. Published builds do; then everyone signs in to Box through it,
/// and nothing about it is shown or asked for (the owner's decision, 8 Nov 2026).
///
/// `GeneratedBoxApp` is written while the app builds, by the "Embed Box App"
/// phase (`scripts/box-app-credentials.sh`), from the building Mac's Keychain
/// into the build folder. So the values are never in the source tree, in git,
/// or in a log. They are masked, so they are not plain text in the binary
/// either — which keeps them from being read off it in passing, not from
/// someone set on finding them. A secret shipped in an app can always be
/// recovered from it, and Box, with no PKCE, leaves no way round shipping one
/// (`BoxAppConfiguration`).
///
/// A build without them — CI's, or anyone's from the public source — asks for
/// a Box app of the person's own, as before.
enum BuiltInBoxApp {
    static var credentials: BuiltInBoxCredentials? {
        guard let masked = GeneratedBoxApp.masked, !masked.key.isEmpty else { return nil }
        func unmask(_ bytes: [UInt8]) -> String {
            String(decoding: bytes.enumerated().map { $0.element ^ masked.key[$0.offset % masked.key.count] },
                   as: UTF8.self)
        }
        let clientID = unmask(masked.id), clientSecret = unmask(masked.secret)
        return clientID.isEmpty || clientSecret.isEmpty
            ? nil : BuiltInBoxCredentials(clientID: clientID, clientSecret: clientSecret)
    }
}
