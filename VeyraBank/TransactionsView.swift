// Transaction history + receipts for one token:
// the customer's payments across all rails (tap/MPM/CPM),
// each row's status, and any scanned merchant receipt linked by transaction hash.
import SwiftUI
import VeyraWallet

struct TransactionsView: View {
    let tokenUniqueReference: String
    let cardName: String

    @State private var history: [TransactionSummary] = []
    @State private var receiptByHash: [String: TransactionReceipt] = [:]
    @State private var loading = true

    var body: some View {
        List {
            if history.isEmpty && !loading {
                Text("No transactions yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, tx in
                // Each row opens the transaction detail screen (view/scan receipt).
                NavigationLink(destination: TransactionDetailView(tx: tx)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tx.merchantName).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(statusText(tx.authorizationStatus))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(tx.authorizationStatus))
                        }
                        HStack {
                            Text(amountText(tx)).font(.footnote).foregroundStyle(.secondary)
                            if let hash = tx.transactionHash, receiptByHash[hash] != nil {
                                Spacer()
                                Label("Receipt", systemImage: "doc.text")
                                    .font(.caption2).foregroundStyle(Brand.crimson)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(cardName)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await reconcileThenLoad() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        history = (try? await VeyraWallet.shared.tokenisation
            .transactionHistory(tokenUniqueReference: tokenUniqueReference, limit: 100)) ?? []
        var receipts: [String: TransactionReceipt] = [:]
        for tx in history {
            guard let hash = tx.transactionHash else { continue }
            if let r = try? await VeyraWallet.shared.tokenisation.receipt(forTransactionHash: hash) {
                receipts[hash] = r
            }
        }
        receiptByHash = receipts
    }

    private func reconcileThenLoad() async {
        // Settle any PENDING rows (CPM QRs are offline) then refresh the list.
        try? await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
        await load()
    }

    private func amountText(_ tx: TransactionSummary) -> String {
        let major = Double(tx.amountInMinorUnit) / 100.0
        return String(format: "%.2f", major)
    }

    private func statusText(_ status: String?) -> String {
        switch status {
        case "APPROVED": return "Approved"
        case "DECLINED": return "Declined"
        case "FAILED": return "Failed"
        case "PENDING": return "Pending"
        default: return "—"
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "APPROVED": return .green
        case "DECLINED", "FAILED": return Brand.crimson
        case "PENDING": return .orange
        default: return .secondary
        }
    }
}
