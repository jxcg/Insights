//
//  ContentView.swift
//  Insights
//
//  Created by Joshua Ng on 11/07/2026.
//

import SwiftUI

/// Minimal launch screen: shows Health availability and lets the user trigger
/// the HealthKit authorization sheet.
struct ContentView: View {
    private let healthKit = HealthKitService()

    @State private var statusMessage = "Not connected"

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tint)
                
                Text("Insights")
                    .font(.system(.largeTitle, design: .serif))
            }

            Text(statusMessage)
                .foregroundStyle(.secondary)
            
            if HealthKitService.isAvailable {
                Button("Connect Apple Health") {
                    Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Health data isn't available on this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    
    }

    private func connect() async {
        do {
            try await healthKit.requestAuthorization()
            statusMessage = "Authorization sheet completed"
        } catch {
            statusMessage = "Authorization failed: \(error.localizedDescription)"
        }
        // May need another way to re-trigger in the event a user does not authorise, but doesn't want to go through Settings (if this is possible; am aware Apple does not make it easy to re-trigger events after a user denies permissions)
    }
}

#Preview {
    ContentView()
}
