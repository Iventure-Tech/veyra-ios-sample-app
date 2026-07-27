// Add a card: choose your bank, check account eligibility, digitise —
// reached from the wallet
// screen's `+`. Prefill comes from SampleData — never hardcode demo values in a view.
import SwiftUI
import VeyraSDK
import VeyraWallet

struct AddCardView: View {
    enum BanksState {
        case loading
        case loaded([Bank])
        case failed(String)
    }

    private let user = SampleData.personal

    @Environment(\.presentationMode) private var presentationMode

    @State private var banksState: BanksState = .loading
    @State private var accountNumber: String
    @State private var selectedInstitutionCode: String
    @State private var eligibility: String?
    @State private var eligibilityError: String?
    @State private var checking = false
    @State private var digitising = false
    @State private var digitiseResult: String?
    @State private var digitiseSucceeded = false
    @State private var digitiseError: String?

    init() {
        _accountNumber = State(initialValue: SampleData.personal.accountNumber)
        _selectedInstitutionCode = State(initialValue: SampleData.personal.institutionCode)
    }

    var body: some View {
        List {
            Section("Account") {
                TextField("Account number", text: $accountNumber)
                    .keyboardType(.numberPad)
                LabeledRow("Account name", value: user.accountName)
                // Bank is a picker loaded from the SDK's banks lookup — not a static code.
                switch banksState {
                case .loading:
                    HStack {
                        ProgressView()
                        Text("Loading banks…").foregroundStyle(.gray)
                    }
                case .loaded(let banks) where !banks.isEmpty:
                    Picker("Bank (institution)", selection: $selectedInstitutionCode) {
                        ForEach(banks) { bank in
                            Text(bank.name).tag(bank.institutionCode)
                        }
                    }
                case .loaded:
                    LabeledRow("Bank (institution)", value: selectedInstitutionCode)
                    Text("No banks returned").font(.footnote).foregroundStyle(.gray)
                case .failed(let message):
                    LabeledRow("Bank (institution)", value: selectedInstitutionCode)
                    Text("Couldn't load banks — \(message)")
                        .font(.footnote).foregroundStyle(Brand.crimson)
                }
                Button("Check eligibility") { Task { await checkEligibility() } }
                    .disabled(accountNumber.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                if checking {
                    HStack {
                        ProgressView()
                        Text("Checking eligibility…").foregroundStyle(.gray)
                    }
                }
                if let eligibility {
                    Text(eligibility)
                        .foregroundStyle(eligibility.contains("APPROVED") ? .green : Brand.crimson)
                }
                if let eligibilityError {
                    Text(eligibilityError).font(.footnote).foregroundStyle(Brand.crimson)
                }
            }
            Section("Add card (digitise)") {
                Button("Digitise this account") { Task { await digitise() } }
                    .disabled(accountNumber.trimmingCharacters(in: .whitespaces).isEmpty || digitising)
                if digitising {
                    HStack {
                        ProgressView()
                        Text("Digitising…").foregroundStyle(.gray)
                    }
                }
                if let digitiseResult {
                    Text(digitiseResult).foregroundStyle(digitiseSucceeded ? .green : .white)
                }
                if digitiseSucceeded {
                    Button("Done — view wallet") { presentationMode.wrappedValue.dismiss() }
                        .foregroundStyle(Brand.crimson)
                }
                if let digitiseError {
                    Text(digitiseError).font(.footnote).foregroundStyle(Brand.crimson)
                }
            }
        }
        .navigationTitle("Add a card")
        .task { await loadBanks() }
    }

    /// The display name of the currently selected bank (for the stored card record).
    private var selectedBankName: String? {
        if case .loaded(let banks) = banksState {
            return banks.first(where: { $0.institutionCode == selectedInstitutionCode })?.name
        }
        return nil
    }

    private func loadBanks() async {
        banksState = .loading
        do {
            let trimmed = accountNumber.trimmingCharacters(in: .whitespaces)
            let banks = try await VeyraWallet.shared.tokenisation.banks(
                accountNumber: trimmed.isEmpty ? nil : trimmed
            )
            // Keep the prefilled institution when it's in the list; otherwise select the first.
            if !banks.contains(where: { $0.institutionCode == selectedInstitutionCode }),
               let first = banks.first {
                selectedInstitutionCode = first.institutionCode
            }
            banksState = .loaded(banks)
        } catch {
            banksState = .failed(String(describing: error))
        }
    }

    private func checkEligibility() async {
        checking = true
        defer { checking = false }
        eligibility = nil
        eligibilityError = nil
        do {
            let response = try await VeyraWallet.shared.tokenisation.verifyAccount(
                accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                institutionCode: selectedInstitutionCode,
                walletAccountID: user.walletAccountID,
                accountHolderName: user.accountName,
                accountNumberSource: "MANUAL" // the account number was keyed in by the user
            )
            eligibility = "\(response.responseCode ?? "unknown")\(response.message.map { " — \($0)" } ?? "")"
        } catch {
            eligibilityError = String(describing: error)
        }
    }

    private func digitise() async {
        digitising = true
        defer { digitising = false }
        digitiseResult = nil
        digitiseSucceeded = false
        digitiseError = nil
        do {
            // Business inputs the wallet provider supplies:
            // APPROVE + TRUSTED/HIGHLY_TRUSTED + GOOD_ACTIVITY_HISTORY, MANUAL entry, UUID
            // consumer identifier. These are the app's calls to make — the SDK never assumes them.
            let r = try await VeyraWallet.shared.tokenisation.digitise(
                accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                institutionCode: selectedInstitutionCode,
                walletAccountID: user.walletAccountID,
                accountHolderName: user.accountName,
                emailAddress: user.emailAddress,
                recommendation: .approve,
                mobileNumber: user.mobileNumber,
                bvn: user.bvn,
                accountHolderAddress: user.fullAddress,
                accountNumberSource: "MANUAL",
                consumerIdentifier: UUID().uuidString,
                deviceScore: .trusted,
                accountScore: .highlyTrusted,
                recommendationReasons: [.goodActivityHistory],
                bankName: selectedBankName
            )
            let stored = r.tokenStored ? " · token stored" : ""
            let tur = r.tokenUniqueReference.map { " · \($0)" } ?? ""
            digitiseResult = "\(r.responseCode ?? "unknown")\(tur)\(stored)"
            digitiseSucceeded = r.tokenStored
        } catch {
            digitiseError = String(describing: error)
        }
    }
}
