// Pay (wallet) — the wallet screen: Apple-Wallet-style stack of the
// tokenised cards this device holds, with `+` to add more (bank → eligibility → digitise,
// AddCardView). Home "Pay" lands here; an empty wallet offers "Add your first card".
// The SDK's token registry drives the list; the active token wears a badge, and each
// card's context menu offers "Set as active" / "Deactivate" (deactivate wipes the token's
// on-device material and promotes the next card — watch the badge move).
import SwiftUI
import VeyraSDK
import VeyraWallet

struct PayView: View {
    enum CardsState {
        case loading
        case loaded([StoredCard])
        case failed(String)
    }

    @State private var state: CardsState = .loading
    /// The card brought to the front (Apple-Wallet-style focus); nil = fanned stack.
    @State private var selectedID: String?
    @State private var actionError: String?
    /// The card queued for removal — drives the confirmation dialog.
    @State private var pendingRemoval: StoredCard?
    @State private var working = false
    /// Payment-keys state for the focused card.
    @State private var lukState: LukState?
    /// Re-derive card state when the app returns to the foreground — the SDK's
    /// scene-active lifecycle sync may have changed statuses (suspended/unfrozen/wiped).
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading your cards…")
            case .failed(let message):
                VStack(spacing: 8) {
                    Text("Couldn't load your cards")
                    Text(message).font(.footnote).foregroundStyle(Brand.crimson)
                    Button("Retry") { Task { await reload() } }
                }
                .padding()
            case .loaded(let cards) where cards.isEmpty:
                emptyState
            case .loaded(let cards):
                cardStack(cards)
            }
        }
        .navigationTitle("Wallet")
        .toolbar {
            // Scan to pay — only
            // meaningful with a card in the wallet (payments use the active token).
            ToolbarItem(placement: .navigationBarTrailing) {
                if case .loaded(let cards) = state, !cards.isEmpty {
                    NavigationLink {
                        ScanToPayView()
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Scan to pay")
                    // No pay affordance while the active card must go online
                    // first or is suspended server-side.
                    .disabled(activeCardBlocked(cards))
                }
            }
            // Show QR to pay (dynamic CPM): present a payment QR the merchant scans.
            ToolbarItem(placement: .navigationBarTrailing) {
                if case .loaded(let cards) = state, !cards.isEmpty {
                    NavigationLink {
                        ShowToPayView()
                    } label: {
                        Image(systemName: "qrcode")
                    }
                    .accessibilityLabel("Show QR to pay")
                    .disabled(activeCardBlocked(cards))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    AddCardView()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add card")
            }
        }
        // Mode is SDK-managed: wallet payments claim WALLET at the point of use and the SDK
        // drops to inert by itself — no screen choreography needed here.
        .onAppear {
            Task { await reload() }
        }
        // The app-level scene hook runs the SDK's lifecycle sync; reload afterwards so
        // the wallet reflects any status change (suspended card greys, deactivated card leaves).
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await reload() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.gray)
                .frame(width: 300, height: 190)
                .overlay(
                    VStack(spacing: 10) {
                        Image(systemName: "creditcard").font(.largeTitle)
                        Text("No cards yet").font(.headline)
                    }
                    .foregroundStyle(.gray)
                )
            NavigationLink {
                AddCardView()
            } label: {
                Label("Add your first card", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Brand.crimson, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Apple-Wallet-style stack: fanned cards peeking; tapping one brings it to the front and
    /// compresses the rest below; tapping again returns to the fan.
    private func cardStack(_ cards: [StoredCard]) -> some View {
        ScrollView {
            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    CardFace(card: card)
                        .offset(y: offsetY(index: index, card: card, in: cards))
                        .zIndex(zIndex(index: index, card: card))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                selectedID = selectedID == card.id ? nil : card.id
                            }
                        }
                        // Wallet management: pick the token payments use, or
                        // deactivate (server + full on-device wipe + promotion).
                        .contextMenu {
                            if !card.isActive {
                                Button {
                                    Task { await setActive(card.tokenUniqueReference) }
                                } label: {
                                    Label("Set as active card", systemImage: "checkmark.circle")
                                }
                            }
                            Button(role: .destructive) {
                                Task { await deactivate(card.tokenUniqueReference) }
                            } label: {
                                Label("Deactivate (removes from device)", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            // Room below the stack for the fanned/compressed offsets.
            .padding(.bottom, CGFloat(cards.count) * 84 + 260)
        }
        .safeAreaInset(edge: .bottom) {
            // Visible call-to-action bar for the focused card (tap a card to focus it) — the
            // discoverable home for Set-active / Remove, alongside the long-press context menu.
            if let selectedID, let card = cards.first(where: { $0.id == selectedID }) {
                cardActions(card)
            }
        }
        .overlay(alignment: .bottom) {
            if let actionError {
                Text(actionError)
                    .font(.footnote).foregroundStyle(Brand.crimson)
                    .padding(.horizontal).padding(.bottom, 90)
                    .multilineTextAlignment(.center)
            }
        }
        .confirmationDialog(
            "Remove this card?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { card in
            Button("Remove \(card.bankName ?? "card")", role: .destructive) {
                Task { await remove(card.tokenUniqueReference) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This deactivates the token and deletes its payment data from this device.")
        }
    }

    private func cardActions(_ card: StoredCard) -> some View {
        VStack(spacing: 10) {
            // Payment-keys indicator: remaining Limited-Use Keys. Refresh is fully
            // SDK-automatic (pre-payment top-up, scene-active, requires-online trigger) — no
            // manual refresh action is exposed.
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.footnote).foregroundStyle(.secondary)
                if let lukState {
                    Text("\(lukState.usableKeyCount) payment key\(lukState.usableKeyCount == 1 ? "" : "s") left")
                        .font(.footnote)
                        .foregroundStyle(lukState.refreshDue ? Brand.crimson : .secondary)
                } else {
                    Text("Checking keys…").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Transaction history + receipts for this token.
            NavigationLink {
                TransactionsView(tokenUniqueReference: card.tokenUniqueReference, cardName: card.bankName ?? "Card")
            } label: {
                Label("Transactions & receipts", systemImage: "list.bullet.rectangle")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if !card.isActive {
                    Button {
                        Task { await setActive(card.tokenUniqueReference) }
                    } label: {
                        Label("Set as active", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(working)
                }
                Button {
                    pendingRemoval = card
                } label: {
                    Label("Remove card", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Brand.crimson, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(working)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .task(id: card.id) { await loadLukState(card.tokenUniqueReference) }
    }

    private func setActive(_ tokenUniqueReference: String) async {
        actionError = nil
        working = true
        defer { working = false }
        do {
            try await VeyraWallet.shared.tokenisation.setActiveToken(tokenUniqueReference)
            await reload()
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Deactivate (used by the long-press menu): backend deactivate + on-device wipe + promotion.
    private func deactivate(_ tokenUniqueReference: String) async {
        actionError = nil
        do {
            _ = try await VeyraWallet.shared.tokenisation.deactivate(tokenUniqueReference)
            await reload() // card gone, next one promoted — the Active badge moves
        } catch {
            actionError = String(describing: error)
        }
    }

    private func loadLukState(_ tokenUniqueReference: String) async {
        lukState = nil
        lukState = try? await VeyraWallet.shared.tokenisation.lukState(tokenUniqueReference: tokenUniqueReference)
    }

    /// Remove (the visible CTA): best-effort backend deactivate + guaranteed local delete, so a
    /// card the user no longer wants always leaves the wallet even if the network is down.
    private func remove(_ tokenUniqueReference: String) async {
        pendingRemoval = nil
        actionError = nil
        working = true
        defer { working = false }
        do {
            try await VeyraWallet.shared.tokenisation.delete(tokenUniqueReference)
            selectedID = nil
            await reload()
        } catch {
            actionError = String(describing: error)
        }
    }

    private func offsetY(index: Int, card: StoredCard, in cards: [StoredCard]) -> CGFloat {
        guard let selectedID else { return CGFloat(index) * 84 } // fanned: each peeks below the last
        if card.id == selectedID { return 0 }                    // focused card at the top
        // The rest compress into a tight stack under the focused card.
        let below = cards.filter { $0.id != selectedID }
        let position = below.firstIndex(where: { $0.id == card.id }) ?? 0
        return 250 + CGFloat(position) * 40
    }

    private func zIndex(index: Int, card: StoredCard) -> Double {
        card.id == selectedID ? 1000 : Double(index)
    }

    /// The active card can't start a payment while it must go online (exhausted
    /// keys) or the issuer has suspended it (polled status; unfreezes on a later ACTIVE poll).
    private func activeCardBlocked(_ cards: [StoredCard]) -> Bool {
        guard let active = cards.first(where: { $0.isActive }) else { return false }
        return active.requiresOnline || active.status.uppercased() == "SUSPENDED"
    }

    private func reload() async {
        do {
            let cards = try await VeyraWallet.shared.tokenisation.tokens()
            withAnimation { state = .loaded(cards) }
            if let selectedID, !cards.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// One card face — bank name + contactless glyph, masked DPAN, holder + expiry, and an
/// activation badge when the token still needs activating.
private struct CardFace: View {
    let card: StoredCard

    /// Polled issuer-side suspension (derived-not-sticky — clears on an ACTIVE poll).
    private var isSuspended: Bool { card.status.uppercased() == "SUSPENDED" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(card.bankName ?? "Veyra")
                    .font(.headline.weight(.semibold))
                if isSuspended {
                    // Issuer-side suspension — non-payable until polled ACTIVE again.
                    Text("Suspended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                } else if card.requiresOnline {
                    // Frozen — the wallet must go online before this card can pay.
                    Text("Connect to internet")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                } else if card.isActive {
                    // The wallet's active token — the one payments use.
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer()
                Image(systemName: "wave.3.right")
                    .font(.title3)
                    .opacity(0.85)
            }
            Spacer()
            Text(card.maskedPAN.isEmpty ? "•••• •••• •••• ••••" : card.maskedPAN)
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .padding(.bottom, 14)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CARD HOLDER").font(.system(size: 9)).opacity(0.6)
                    // The SDK derives the card's display name — scheme label + masked last four,
                    // e.g. "AFRIGO ****1234". Blank on cards digitised before it supplied one.
                    Text(card.cardHolderName.isEmpty ? "CARDHOLDER" : card.cardHolderName)
                        .font(.footnote.weight(.medium))
                }
                Spacer()
                if !card.expiry.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("EXPIRES").font(.system(size: 9)).opacity(0.6)
                        Text(card.expiry).font(.footnote.weight(.medium))
                    }
                }
                if card.requiresActivation {
                    Text("Needs activation")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.yellow.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(gradient)
        // A requires-online or suspended card renders frozen — desaturated, dimmed.
        .saturation(card.requiresOnline || isSuspended ? 0 : 1)
        .opacity(card.requiresOnline || isSuspended ? 0.55 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .foregroundStyle(.white)
    }

    /// Stable per-card gradient (keyed by the TUR) from a small dark, brand-adjacent palette.
    private var gradient: LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.10, green: 0.10, blue: 0.12), Color(red: 0.30, green: 0.05, blue: 0.08)], // black → crimson
            [Color(red: 0.07, green: 0.10, blue: 0.20), Color(red: 0.12, green: 0.25, blue: 0.45)], // navy
            [Color(red: 0.05, green: 0.18, blue: 0.14), Color(red: 0.10, green: 0.35, blue: 0.24)], // green
            [Color(red: 0.16, green: 0.09, blue: 0.24), Color(red: 0.33, green: 0.16, blue: 0.45)], // purple
        ]
        var hash = 0
        for scalar in card.tokenUniqueReference.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        let colors = palettes[abs(hash) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
