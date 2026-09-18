//
//  AssetEditView.swift
//  자산 포트폴리오 앱
//
//  국내주식/해외주식/금 종목을 추가·수정·삭제하는 폼입니다. 기존 코인 등록 폼과 같은
//  디자인 톤(Form + Section)으로 맞췄습니다. 종목코드/티커가 prices.json 유니버스에
//  없으면 "시세 데이터에 없는 종목입니다" 안내와 함께 수동 현재가 입력 옵션을 보여줍니다.
//

import SwiftUI

struct AssetEditView: View {
    let assetClass: HoldingAssetClass
    var existing: StockGoldHolding?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var priceService = PriceService.shared
    @StateObject private var store = StockGoldStore.shared

    @State private var symbol: String = ""
    @State private var displayName: String = ""
    @State private var quantityText: String = ""
    @State private var avgCostText: String = ""
    @State private var memo: String = ""

    @State private var useManualPrice = false
    @State private var manualPriceText: String = ""

    @State private var showDeleteConfirm = false

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(assetClass.rawValue + " 정보") {
                    if assetClass != .gold {
                        TextField(assetClass == .domesticStock ? "종목코드 (예: 005930)" : "티커 (예: AAPL)", text: $symbol)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            // iOS16 최소 타겟이라 onChange는 구형(단일 파라미터) 시그니처를 씁니다.
                        .onChange(of: symbol) { _ in updateUniverseCheck() }
                    }
                    TextField("표시 이름 (예: 삼성전자)", text: $displayName)

                    TextField(assetClass == .gold ? "보유 중량 (g)" : "보유 수량 (주)", text: $quantityText)
                        .keyboardType(.decimalPad)

                    TextField(unitLabel(for: "평균매입단가"), text: $avgCostText)
                        .keyboardType(.decimalPad)
                }

                if assetClass != .gold {
                    universeStatusSection
                }

                Section("메모") {
                    TextField("메모(선택)", text: $memo, axis: .vertical)
                }

                if isEditing {
                    Section {
                        Button("이 종목 삭제", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "\(assetClass.rawValue) 수정" : "\(assetClass.rawValue) 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(!isFormValid)
                }
            }
            .onAppear { populateIfEditing() }
            .confirmationDialog("정말 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    if let existing { store.delete(id: existing.id) }
                    dismiss()
                }
                Button("취소", role: .cancel) {}
            }
        }
    }

    // MARK: - 유니버스(시세 데이터) 상태 안내

    @ViewBuilder
    private var universeStatusSection: some View {
        let known = isKnownInUniverse

        Section {
            if symbol.isEmpty {
                EmptyView()
            } else if known {
                Label("시세 데이터에 있는 종목이에요", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.footnote)
            } else {
                Label("시세 데이터에 없는 종목입니다", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)

                Toggle("현재가 직접 입력하기", isOn: $useManualPrice)

                if useManualPrice {
                    TextField(unitLabel(for: "현재가"), text: $manualPriceText)
                        .keyboardType(.decimalPad)
                    Text("이 종목은 매일 자동 갱신되는 시세 목록(코스피·코스닥 전종목 또는 S&P500·나스닥100)에 없어서, 자동으로 값을 갱신하지 못해요. 직접 입력한 값은 다음에 이 화면에서 고치기 전까지 그대로 사용됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isKnownInUniverse: Bool {
        switch assetClass {
        case .domesticStock: return priceService.isKnownDomesticStock(code: symbol)
        case .foreignStock: return priceService.isKnownForeignStock(ticker: symbol)
        case .gold: return true
        }
    }

    private func updateUniverseCheck() {
        // symbol이 바뀔 때 자동으로 다시 그려지도록 @State 트리거 역할만 합니다.
        if isKnownInUniverse { useManualPrice = false }
    }

    // MARK: - 단위 라벨

    private func unitLabel(for base: String) -> String {
        switch assetClass {
        case .domesticStock: return "\(base) (원/주)"
        case .foreignStock: return "\(base) (달러/주)"
        case .gold: return "\(base) (원/g)"
        }
    }

    // MARK: - 폼 유효성

    private var isFormValid: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard Double(quantityText) != nil, Double(quantityText)! > 0 else { return false }
        guard Double(avgCostText) != nil, Double(avgCostText)! >= 0 else { return false }
        if assetClass != .gold {
            guard !symbol.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if useManualPrice && Double(manualPriceText) == nil { return false }
        }
        return true
    }

    // MARK: - 불러오기 / 저장

    private func populateIfEditing() {
        guard let existing else {
            // 금은 종목코드 개념이 없으니 표시용 기본값만 넣어둡니다.
            if assetClass == .gold { symbol = "금현물" }
            return
        }
        symbol = existing.symbol
        displayName = existing.displayName
        quantityText = String(existing.quantity)
        avgCostText = String(existing.avgCost)
        memo = existing.memo
        if let manual = existing.manualPrice {
            useManualPrice = true
            manualPriceText = String(manual)
        }
    }

    private func save() {
        let holding = StockGoldHolding(
            id: existing?.id ?? UUID(),
            assetClass: assetClass,
            symbol: symbol,
            displayName: displayName,
            quantity: Double(quantityText) ?? 0,
            avgCost: Double(avgCostText) ?? 0,
            manualPrice: (assetClass != .gold && useManualPrice) ? Double(manualPriceText) : nil,
            memo: memo,
            createdAt: existing?.createdAt ?? Date()
        )
        if existing != nil {
            store.update(holding)
        } else {
            store.add(holding)
        }
        dismiss()
    }
}
