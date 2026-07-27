// Merchant settings — register (no stored merchant yet) or edit the stored profile; reached
// from Home's settings gear, and runs with no reader claimed.
// Registration prefill comes from SampleData, edit prefill from the
// SDK's stored merchant — never hardcode demo values in a view. Personal vs Business: one
// identity, the only business-specific field is the CAC number. Registration form:
// every field is an editable, SampleData-prefilled input, and the request carries the
// form values.
import SwiftUI
import VeyraSDK
import VeyraSoftPOS

struct MerchantSettingsView: View {
    @State private var stored: StoredMerchant?

    // Shared form state (registration and edit).
    @State private var isBusiness = false
    @State private var merchantName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var accountNumber = ""
    // Every registration-form field is an editable, prefilled input.
    @State private var addressLine1 = ""
    @State private var addressLine2 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var countryCode = ""
    @State private var acquirerID = ""
    @State private var bvn = ""
    @State private var cacNumber = ""
    @State private var busy = false
    @State private var resultText: String?
    @State private var errorText: String?

    // Bank picker: the registration/edit forms use a dropdown loaded from the SDK's
    // banks lookup, preselected to the sample/stored institution; static code shown as fallback
    // while loading or on failure.
    @State private var banks: [SettlementBank] = []
    @State private var selectedBankCode = ""

    private var sample: SampleMerchant { isBusiness ? SampleData.business : SampleData.personal }

    /// Prefill at **init** (before first render), not in `onAppear`: values set in `onAppear`
    /// don't reflect in a `TextField` until the field re-renders (which is why they only
    /// appeared after focusing each one). `merchant.stored` is synchronous, so the whole form
    /// can be seeded here and shows populated on load.
    init() {
        let storedMerchant = VeyraSoftPOS.shared.merchant.stored
        _stored = State(initialValue: storedMerchant)

        let s = SampleData.personal // registration defaults (isBusiness starts false)
        _merchantName = State(initialValue: storedMerchant?.merchantName ?? s.merchantName)
        _email = State(initialValue: storedMerchant?.emailAddress ?? s.emailAddress)
        _phone = State(initialValue: storedMerchant?.phoneNumber ?? s.mobileNumber)
        _accountNumber = State(initialValue: storedMerchant?.accountNumber ?? s.accountNumber)
        _selectedBankCode = State(initialValue: storedMerchant?.institutionCode ?? s.institutionCode)
        _addressLine1 = State(initialValue: s.addressLine1)
        _addressLine2 = State(initialValue: s.addressLine2)
        _city = State(initialValue: s.city)
        _state = State(initialValue: s.state)
        _countryCode = State(initialValue: s.countryCode)
        _acquirerID = State(initialValue: s.acquirerID)
        _bvn = State(initialValue: s.bvn)
        _cacNumber = State(initialValue: s.cacNumber ?? "")
    }

    var body: some View {
        List {
            if let merchant = stored {
                editSections(merchant)
            } else {
                registrationSection
            }
        }
        .navigationTitle(stored == nil ? "Register merchant" : "Merchant settings")
        .task { await loadBanks() }
    }

    /// Refresh after register / clear (user-driven, so re-render already happens): re-read the
    /// stored merchant and re-seed the fields.
    private func load() {
        stored = VeyraSoftPOS.shared.merchant.stored
        if let merchant = stored {
            merchantName = merchant.merchantName
            email = merchant.emailAddress
            phone = merchant.phoneNumber
            accountNumber = merchant.accountNumber
            selectedBankCode = merchant.institutionCode
        } else {
            prefillFromSample()
        }
    }

    /// All demo defaults come from SampleData —
    /// one shared identity; Personal and Business differ only by the CAC number.
    private func prefillFromSample() {
        merchantName = sample.merchantName
        email = sample.emailAddress
        phone = sample.mobileNumber
        accountNumber = sample.accountNumber
        selectedBankCode = sample.institutionCode
        addressLine1 = sample.addressLine1
        addressLine2 = sample.addressLine2
        city = sample.city
        state = sample.state
        countryCode = sample.countryCode
        acquirerID = sample.acquirerID
        bvn = sample.bvn
        cacNumber = sample.cacNumber ?? ""
    }

    private func loadBanks() async {
        banks = (try? await VeyraSoftPOS.shared.merchant.banks()) ?? []
    }

    /// Bank dropdown once the list is loaded; the institution code as a static row meanwhile.
    @ViewBuilder
    private var bankRow: some View {
        if banks.isEmpty {
            LabeledRow("Bank (institution)", value: selectedBankCode)
        } else {
            Picker("Bank", selection: $selectedBankCode) {
                ForEach(banks) { bank in
                    Text(bank.name).tag(bank.institutionCode)
                }
            }
        }
    }

    private var registrationSection: some View {
        Section("Register merchant") {
            Picker("Merchant type", selection: $isBusiness) {
                Text("Personal").tag(false)
                Text("Business").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: isBusiness) { _ in
                // Entering the form for a type re-populates the demo defaults.
                if stored == nil { prefillFromSample() }
            }
            TextField("Merchant name", text: $merchantName)
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            TextField("Phone", text: $phone)
                .keyboardType(.phonePad)
            TextField("Address line 1", text: $addressLine1)
            TextField("Address line 2", text: $addressLine2)
            TextField("City", text: $city)
            TextField("State", text: $state)
            TextField("Country code (numeric)", text: $countryCode)
                .keyboardType(.numberPad)
            TextField("Account number", text: $accountNumber)
                .keyboardType(.numberPad)
            bankRow
            TextField("Acquirer ID", text: $acquirerID)
            // BVN applies to both types; the CAC field only to a business.
            TextField("BVN", text: $bvn)
                .keyboardType(.numberPad)
            if isBusiness {
                TextField("CAC number", text: $cacNumber)
            }
            Button("Register") { Task { await register() } }
                .disabled(busy)
            progressAndMessages(busyLabel: "Registering…")
        }
    }

    @ViewBuilder
    private func editSections(_ merchant: StoredMerchant) -> some View {
        Section("Registered merchant") {
            LabeledRow("Merchant ID", value: merchant.merchantID)
            LabeledRow("Terminal", value: merchant.terminalID)
            LabeledRow("Type", value: merchant.merchantType)
            LabeledRow("Status", value: merchant.merchantStatus ?? "UNKNOWN")
        }
        Section("Edit profile") {
            TextField("Merchant name", text: $merchantName)
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            TextField("Phone", text: $phone)
                .keyboardType(.phonePad)
            TextField("Account number", text: $accountNumber)
                .keyboardType(.numberPad)
            bankRow
            Button("Save changes") { Task { await saveChanges(merchant) } }
                .disabled(busy)
            progressAndMessages(busyLabel: "Saving…")
        }
        Section {
            Button("Clear registration", role: .destructive) {
                VeyraSoftPOS.shared.merchant.clearStored()
                resultText = nil
                errorText = nil
                load()
            }
        } footer: {
            Text("Sample-only: clears the merchant stored on this device so you can register again.")
        }
    }

    @ViewBuilder
    private func progressAndMessages(busyLabel: String) -> some View {
        if busy {
            HStack {
                ProgressView()
                Text(busyLabel).foregroundStyle(.gray)
            }
        }
        if let resultText {
            Text(resultText).foregroundStyle(.green)
        }
        if let errorText {
            Text(errorText).font(.footnote).foregroundStyle(Brand.crimson)
        }
    }

    private func register() async {
        busy = true
        defer { busy = false }
        resultText = nil
        errorText = nil
        do {
            // The request carries the (possibly edited) form values; the
            // country code is zero-padded to 4 digits, BVN rides personal-only, CAC business-only.
            let paddedCountry = String(repeating: "0", count: max(0, 4 - countryCode.trimmingCharacters(in: .whitespaces).count))
                + countryCode.trimmingCharacters(in: .whitespaces)
            let result = try await VeyraSoftPOS.shared.merchant.register(
                MerchantRegistration(
                    merchantType: isBusiness ? .business : .personal,
                    merchantName: merchantName.trimmingCharacters(in: .whitespaces),
                    emailAddress: email.trimmingCharacters(in: .whitespaces),
                    phoneNumber: phone.trimmingCharacters(in: .whitespaces),
                    addressLine1: addressLine1.trimmingCharacters(in: .whitespaces),
                    addressLine2: addressLine2.trimmingCharacters(in: .whitespaces),
                    city: city.trimmingCharacters(in: .whitespaces),
                    state: state.trimmingCharacters(in: .whitespaces),
                    countryCode: paddedCountry,
                    bvn: isBusiness ? nil : bvn.trimmingCharacters(in: .whitespaces),
                    cacNumber: isBusiness ? cacNumber.trimmingCharacters(in: .whitespaces) : nil,
                    accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                    institutionCode: selectedBankCode,
                    acquirerID: acquirerID.trimmingCharacters(in: .whitespaces)
                )
            )
            if result.success {
                // The SDK has persisted the merchant — reload so the screen flips to edit mode
                // and Home unlocks Get paid on return.
                resultText = "Registered: \(result.merchantID ?? "?") · terminal \(result.terminalID ?? "?")"
                load()
            } else {
                errorText = result.message ?? "Registration declined"
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    private func saveChanges(_ merchant: StoredMerchant) async {
        busy = true
        defer { busy = false }
        resultText = nil
        errorText = nil
        do {
            let status = try await VeyraSoftPOS.shared.merchant.update(
                merchantID: merchant.merchantID,
                MerchantUpdate(
                    merchantName: merchantName.trimmingCharacters(in: .whitespaces),
                    emailAddress: email.trimmingCharacters(in: .whitespaces),
                    phoneNumber: phone.trimmingCharacters(in: .whitespaces),
                    addressLine1: merchant.addressLine1,
                    addressLine2: merchant.addressLine2,
                    city: merchant.city,
                    state: merchant.state,
                    countryCode: merchant.countryCode,
                    accountNumber: accountNumber.trimmingCharacters(in: .whitespaces),
                    institutionCode: selectedBankCode.isEmpty ? merchant.institutionCode : selectedBankCode,
                    acquirerID: merchant.acquirerID
                )
            )
            resultText = "Profile updated (\(status.status ?? "OK"))"
            load()
        } catch {
            errorText = String(describing: error)
        }
    }
}
