//
//  ANVILFabricRootView.swift
//  Conduit
//
//  Standalone native operator surface for ANVIL/SIEVE Rooms.
//
//  No Hermes dashboard, ticket, WebSocket, or SavedDashboard is required.
//  The Room Hub remains the network seam and ANVIL remains authority.
//

import SwiftUI

struct ANVILFabricRootView: View {
    @EnvironmentObject private var appState: AppState

    private let workspaceID: UUID

    init(workspaceID: UUID = ANVILFabricModeStore.activeWorkspaceID()) {
        self.workspaceID = workspaceID
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                RoomListView(dashboardIDOverride: workspaceID)
            }
            .navigationTitle(AppLocalization.string("ANVIL Fabric"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Switching presentation modes is not logout and does
                        // not destroy Fabric credentials. Hermes restoration
                        // runs only after the operator explicitly asks for it.
                        appState.leaveANVILFabricMode()
                    } label: {
                        Label(
                            AppLocalization.string("Hermes Dashboard"),
                            systemImage: "server.rack"
                        )
                    }
                    .accessibilityIdentifier("fabric.return-hermes")
                }
            }
        }
        .accessibilityIdentifier("fabric.root")
    }
}
