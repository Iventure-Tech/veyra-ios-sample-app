// Add a card: choose your bank, check account eligibility, digitise —
// reached from the wallet
// screen's `+`. Prefill comes from SampleData and the signed-in customer — never hardcode demo
// values in a view. Customer id, account name, BVN and email are editable, and what is
// entered is what is sent.
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
    // Who is adding the card, as entered on this form (pre-filled, editable). The customer id is
    // signed in to the SDKs and sent as the consumer id.
    @State private var customerID: String
    @State private var accountName: String
    @State private var bvn: String
    // Also the wallet account id: the SDK hashes it and the issuer compares that hash with the
    // email/phone registered on the account.
    @State private var email: String
    @State private var eligibility: String?
    @State private var eligibilityError: String?
    @State private var checking = false
    @State private var digitising = false
    @State private var digitiseResult: String?
    @State private var digitiseSucceeded = false
    @State private var digitiseError: String?
    @State private var formError: String?

    init() {
        _accountNumber = State(initialValue: SampleData.personal.accountNumber)
        _selectedInstitutionCode = State(initialValue: SampleData.personal.institutionCode)
        _customerID = State(initialValue: DemoSession.customerID)
        _accountName = State(initialValue: SampleData.personal.accountName)
        _bvn = State(initialValue: SampleData.personal.bvn)
        _email = State(initialValue: SampleData.personal.emailAddress)
    }

    var body: some View {
        List {
            Section("Account") {
                TextField("Account number", text: $accountNumber)
                    .keyboardType(.numberPad)
                TextField("Customer ID", text: $customerID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Account name", text: $accountName)
                    .textInputAutocapitalization(.words)
                TextField("BVN", text: $bvn)
                    .keyboardType(.numberPad)
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let formError {
                    Text(formError).font(.footnote).foregroundStyle(Brand.crimson)
                }
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

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }

    /// Checks the identity fields and signs in the customer they name. The card belongs to that
    /// customer, so if someone else is signed in the SDKs switch first. False (with a message on
    /// the form) when a field is blank; nothing is sent then.
    private func signInEnteredCustomer() -> Bool {
        formError = nil
        if trimmed(customerID).isEmpty { formError = "Enter the customer ID"; return false }
        if trimmed(accountName).isEmpty { formError = "Enter the account name"; return false }
        if trimmed(bvn).isEmpty { formError = "Enter the BVN"; return false }
        if !isPlausibleEmail(trimmed(email)) { formError = "Enter a valid email"; return false }
        if !DemoSession.isSignedIn || DemoSession.customerID != trimmed(customerID) {
            DemoSession.signIn(trimmed(customerID))
        }
        return true
    }

    /// Something@something.tld — enough to catch a slip; the issuer is the real check.
    private func isPlausibleEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
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
        guard signInEnteredCustomer() else { return }
        checking = true
        defer { checking = false }
        eligibility = nil
        eligibilityError = nil
        do {
            let response = try await VeyraWallet.shared.tokenisation.verifyAccount(
                accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                institutionCode: selectedInstitutionCode,
                walletAccountID: trimmed(email),
                accountHolderName: trimmed(accountName),
                accountNumberSource: "MANUAL" // the account number was keyed in by the user
            )
            eligibility = "\(response.responseCode ?? "unknown")\(response.message.map { " — \($0)" } ?? "")"
        } catch {
            eligibilityError = String(describing: error)
        }
    }

    private func digitise() async {
        guard signInEnteredCustomer() else { return }
        digitising = true
        defer { digitising = false }
        digitiseResult = nil
        digitiseSucceeded = false
        digitiseError = nil
        do {
            // Business inputs the wallet provider supplies:
            // APPROVE + TRUSTED/HIGHLY_TRUSTED + GOOD_ACTIVITY_HISTORY, MANUAL entry, and the
            // entered customer id as the consumer identifier. These are the app's calls to make —
            // the SDK never assumes them.
            let r = try await VeyraWallet.shared.tokenisation.digitise(
                accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                institutionCode: selectedInstitutionCode,
                walletAccountID: trimmed(email),
                accountHolderName: trimmed(accountName),
                emailAddress: trimmed(email),
                recommendation: .approve,
                mobileNumber: user.mobileNumber,
                bvn: trimmed(bvn),
                accountHolderAddress: user.fullAddress,
                accountNumberSource: "MANUAL",
                consumerIdentifier: trimmed(customerID),
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
