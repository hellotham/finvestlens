//
//  FavouriteAccountsTests.swift
//  FinvestLens — FeatureUI
//
//  Sidebar favourites: accounts pinned in the order they were favourited,
//  persisted with the book (KVP slot), tolerant of deleted accounts.
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import FinvestLensEngine
@testable import FinvestLensUI

@MainActor
@Suite("Favourite accounts")
struct FavouriteAccountsTests {

    private func makeModel() throws -> (AppModel, URL, everyday: GncGUID, groceries: GncGUID) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("finvestlens")
        let model = AppModel()
        try model.newDocument(at: url)
        let everyday = try #require(model.addAccount(name: "Everyday", type: .bank))
        let groceries = try #require(model.addAccount(name: "Groceries", type: .expense))
        return (model, url, everyday, groceries)
    }

    @Test("Toggling pins and unpins, keeping the order favourites were added")
    func toggleAndOrder() throws {
        let (model, url, everyday, groceries) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        #expect(!model.isFavouriteAccount(everyday))
        model.toggleFavouriteAccount(groceries)
        model.toggleFavouriteAccount(everyday)
        #expect(model.isFavouriteAccount(everyday))
        // Order is favourited order, not tree order.
        #expect(model.favouriteAccountNodes.map(\.name) == ["Groceries", "Everyday"])

        model.toggleFavouriteAccount(groceries)
        #expect(!model.isFavouriteAccount(groceries))
        #expect(model.favouriteAccountNodes.map(\.name) == ["Everyday"])
    }

    @Test("Favourites persist in the book's KVP slot and reload from it")
    func persistsInBookKvp() throws {
        let (model, url, everyday, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.toggleFavouriteAccount(everyday)
        // Blank the mirror, then reload from the book — proves the slot
        // round-trips (what a save/reopen replays).
        model.favouriteAccountIDs = []
        model.reloadKvpCollections()
        #expect(model.favouriteAccountIDs == [everyday])

        // Removing the last favourite clears the slot entirely, so an
        // untouched book carries nothing extra.
        model.toggleFavouriteAccount(everyday)
        #expect(model.book?.kvp["finvestlens/favouriteAccounts"] == nil)
    }

    @Test("An id whose account is gone stays stored but never renders")
    func deletedAccountDropsOut() throws {
        let (model, url, everyday, _) = try makeModel()
        defer { model.close(); try? FileManager.default.removeItem(at: url) }

        model.toggleFavouriteAccount(everyday)
        model.favouriteAccountIDs.append(.random())   // simulates a deleted account
        #expect(model.favouriteAccountNodes.map(\.name) == ["Everyday"])
        #expect(model.favouriteAccountIDs.count == 2)  // kept, so undoing a delete restores it
    }
}
