// Live-test fixture app (dev.chauffeur.fixture): tabs, toolbar, alert, prompts, form, long list, crash.
import CoreLocation
import SwiftUI
import UserNotifications
import os

let events = Logger(subsystem: "dev.chauffeur.fixture", category: "events")

@main
struct FixtureApp: App {
    @State private var tab = "home"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house") }.tag("home")
                NavigationStack { FormView() }.tabItem { Label("Form", systemImage: "square.and.pencil") }.tag("form")
            }
            // chauffeur-fixture://form and chauffeur-fixture://home select a tab (for `chauffeur open`).
            .onOpenURL { url in
                events.info("fixture: opened \(url.absoluteString, privacy: .public)")
                if url.host == "form" || url.host == "home" { tab = url.host ?? "home" }
            }
        }
    }
}

final class LocationAsker {
    let manager = CLLocationManager()
    func ask() { manager.requestWhenInUseAuthorization() }
}

struct HomeView: View {
    @State private var filter = "All"
    @State private var showAlert = false
    @State private var lastAction = "none"
    private let location = LocationAsker()

    var body: some View {
        List {
            Section("Status") {
                Text("Last action: \(lastAction)").accessibilityIdentifier("lastAction")
            }
            Section("Actions") {
                Button("Show alert") { showAlert = true; events.info("fixture: show alert") }
                Button("Request location") { lastAction = "location"; location.ask(); events.info("fixture: request location") }
                Button("Request notifications") {
                    lastAction = "notifications"
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
                    events.info("fixture: request notifications")
                }
                NavigationLink("Long list") { LongListView() }
                Button("Log errors") {
                    lastAction = "logged errors"
                    for i in 1...4 { events.error("fixture: error \(i, privacy: .public)") }
                }
                Button("Crash", role: .destructive) { events.fault("fixture: crashing"); fatalError("fixture crash") }
            }
        }
        .navigationTitle("Fixture")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Filter", selection: $filter) {
                    Text("All").tag("All")
                    Text("Mine").tag("Mine")
                }
                .pickerStyle(.segmented)
                .onChange(of: filter) { _, new in lastAction = "filter \(new)" }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { lastAction = "toolbar add"; events.info("fixture: toolbar add") } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .alert("Fixture alert", isPresented: $showAlert) {
            Button("OK") { lastAction = "alert ok" }
            Button("Cancel", role: .cancel) { lastAction = "alert cancel" }
        }
    }
}

struct LongListView: View {
    var body: some View {
        List(1...60, id: \.self) { i in Text("Row \(i)") }
            .navigationTitle("Long list")
    }
}

struct FormView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var agree = false
    @State private var submitted = ""

    var body: some View {
        Form {
            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("email")
            SecureField("Password", text: $password).accessibilityIdentifier("password")
            Toggle("Agree to terms", isOn: $agree)
            Button("Submit") { submitted = email; events.info("fixture: submit \(email, privacy: .public)") }
                .disabled(email.isEmpty || password.isEmpty || !agree)
            if !submitted.isEmpty {
                Text("Submitted: \(submitted)").accessibilityIdentifier("submitted")
            }
        }
        .navigationTitle("Form")
    }
}
