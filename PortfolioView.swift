//
//  PortfolioView.swift
//  자산 포트폴리오 앱
//
//  ⚠️ 병합 안내: 이 파일은 "기존 코인 섹션은 그대로 두고 국내주식/해외주식/금 섹션을
//  추가"하라는 요청에 따라 작성했지만, 실제 기존 PortfolioView.swift 원본 코드를
//  제가 갖고 있지 않습니다. 아래 `coinSection`과 `coinTotalKRW`에는 실제 코인 화면
//  코드가 들어갈 자리를 명확히 표시해 두었으니, 기존 파일에서 코인 관련 View 코드와
//  합계 계산 코드를 그대로 옮겨와 그 자리에 붙여 넣어 주세요. 그 외(국내주식/해외주식/
//  금 섹션, 합계 카드)는 완성된 코드입니다.
//

import SwiftUI

struct PortfolioView: View {
    @StateObject private var priceService = PriceService.shared
    @StateObject private var store = StockGoldStore.shared

    // ⚠️ 기존 코인 저장소로 교체하세요(클래스 이름·프로퍼티는 실제 프로젝트에 맞게 수정).
    // @StateObject private var coinStore = CoinStore.shared

    @State private var showAddSheet = false
    @State private var addingClass: HoldingAssetClass = .domesticStock
    @State private var editingHolding: StockGoldHolding?

    var body: some View {
        NavigationStack {
            List {
                coinSection

                assetSection(for: .domesticStock, title: "국내주식")
                assetSection(for: .foreignStock, title: "해외주식")
                goldSection

                totalSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("자산 포트폴리오")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("국내주식 추가") { addingClass = .domesticStock; showAddSheet = true }
                        Button("해외주식 추가") { addingClass = .foreignStock; showAddSheet = true }
                        Button("금 추가") { addingClass = .gold; showAddSheet = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AssetEditView(assetClass: addingClass, existing: nil)
            }
            .sheet(item: $editingHolding) { holding in
                AssetEditView(assetClass: holding.assetClass, existing: holding)
            }
        }
    }

    // MARK: - 코인 섹션 (기존 코드 자리 — 아래는 자리 표시용 자리채우기입니다)

    @ViewBuilder
    private var coinSection: some View {
        Section {
            // ⚠️ 여기에 기존 코인 목록 표시 코드를 그대로 붙여넣으세요.
            // 예시(자리 표시용):
            Text("기존 코인 섹션 자리 — 실제 코인 목록 View로 교체하세요")
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("🪙 코인")
                Spacer()
                // ⚠️ 기존 "지금 시세 가져오기" 버튼 + "마지막 시세 조회: ..." 문구를 그대로 두세요.
            }
        }
    }

    /// ⚠️ 기존 코인 보유분의 원화 환산 합계 계산 로직으로 교체하세요.
    private var coinTotalKRW: Double {
        0 // TODO: coinStore.holdings.reduce(0) { $0 + ($1.quantity * $1.currentPriceKRW) } 형태로 교체
    }

    // MARK: - 국내주식 / 해외주식 공용 섹션

    @ViewBuilder
    private func assetSection(for assetClass: HoldingAssetClass, title: String) -> some View {
        Section {
            let list = store.holdings(for: assetClass)
            if list.isEmpty {
                Text("등록된 \(title) 종목이 없어요.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list) { holding in
                    holdingRow(holding, assetClass: assetClass)
                        .contentShape(Rectangle())
                        .onTapGesture { editingHolding = holding }
                }
                .onDelete { offsets in
                    for index in offsets { store.delete(id: list[index].id) }
                }
            }
        } header: {
            refreshHeader(title: assetClass == .domesticStock ? "🇰🇷 국내주식" : "🌎 해외주식")
        }
    }

    @ViewBuilder
    private var goldSection: some View {
        Section {
            let list = store.holdings(for: .gold)
            if list.isEmpty {
                Text("등록된 금 보유분이 없어요.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list) { holding in
                    holdingRow(holding, assetClass: .gold)
                        .contentShape(Rectangle())
                        .onTapGesture { editingHolding = holding }
                }
                .onDelete { offsets in
                    for index in offsets { store.delete(id: list[index].id) }
                }
            }
            // 출처 표기는 실제로 그 데이터를 쓴 경우에만 붙입니다(KOGL 제4유형 출처 표시 의무).
            if priceService.isGoldFromPublicData {
                Text("자료: 공공데이터포털 금융위원회_일반상품시세정보")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if priceService.goldPricePerGram != nil {
                Text("국제 금시세(COMEX 금선물)를 원/g으로 환산한 추정치예요. KRX 금시장 종가와는 차이가 있을 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            refreshHeader(title: "🥇 금")
        }
    }

    @ViewBuilder
    private func refreshHeader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Button {
                    Task { await priceService.fetchPrices() }
                } label: {
                    if priceService.isLoading {
                        ProgressView()
                    } else {
                        Label("지금 시세 가져오기", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
            }
            if let last = priceService.lastFetchedAt {
                Text("마지막 시세 조회: \(last.formatted(date: .abbreviated, time: .shortened)) 기준")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("아직 시세를 불러오지 않았어요")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }

    // MARK: - 종목 한 줄

    @ViewBuilder
    private func holdingRow(_ holding: StockGoldHolding, assetClass: HoldingAssetClass) -> some View {
        let eval = evalAmountKRW(holding)
        let ret = returnPct(holding)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(holding.displayName)
                    .font(.headline)
                Spacer()
                Text(eval.map { formatKRW($0) } ?? "시세 없음")
                    .font(.headline)
            }
            HStack {
                Text("\(holding.symbol) · \(formatQuantity(holding.quantity, assetClass: assetClass))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ret {
                    Text(String(format: "%+.2f%%", ret))
                        .font(.caption)
                        .foregroundStyle(ret >= 0 ? .red : .blue) // 국내 관례: 상승 빨강/하락 파랑
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 합계 / 비중

    @ViewBuilder
    private var totalSection: some View {
        Section("합계") {
            let domestic = totalKRW(for: .domesticStock)
            let foreign = totalKRW(for: .foreignStock)
            let gold = totalKRW(for: .gold)
            let grandTotal = domestic + foreign + gold + coinTotalKRW

            weightRow(label: "🪙 코인", amount: coinTotalKRW, total: grandTotal)
            weightRow(label: "🇰🇷 국내주식", amount: domestic, total: grandTotal)
            weightRow(label: "🌎 해외주식", amount: foreign, total: grandTotal)
            weightRow(label: "🥇 금", amount: gold, total: grandTotal)

            HStack {
                Text("총자산").font(.headline)
                Spacer()
                Text(formatKRW(grandTotal)).font(.headline)
            }
        }
    }

    @ViewBuilder
    private func weightRow(label: String, amount: Double, total: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(formatKRW(amount))
                .foregroundStyle(.secondary)
            Text(total > 0 ? String(format: "(%.1f%%)", amount / total * 100) : "(0.0%)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    // MARK: - 계산 헬퍼

    /// 종목 1개의 평가액을 원화 기준으로 환산합니다. 시세를 못 찾으면 nil.
    private func evalAmountKRW(_ holding: StockGoldHolding) -> Double? {
        switch holding.assetClass {
        case .domesticStock:
            guard let price = holding.manualPrice ?? priceService.krClose(code: holding.symbol) else { return nil }
            return price * holding.quantity

        case .foreignStock:
            guard let priceUSD = holding.manualPrice ?? priceService.usClose(ticker: holding.symbol),
                  let fx = priceService.usdKrw else { return nil }
            return priceUSD * holding.quantity * fx

        case .gold:
            guard let pricePerG = priceService.goldPricePerGram else { return nil }
            return pricePerG * holding.quantity
        }
    }

    /// 수익률은 통화를 섞지 않고(매입단가·현재가가 같은 통화) 계산합니다.
    private func returnPct(_ holding: StockGoldHolding) -> Double? {
        guard holding.avgCost > 0 else { return nil }
        let currentPrice: Double?
        switch holding.assetClass {
        case .domesticStock:
            currentPrice = holding.manualPrice ?? priceService.krClose(code: holding.symbol)
        case .foreignStock:
            currentPrice = holding.manualPrice ?? priceService.usClose(ticker: holding.symbol)
        case .gold:
            currentPrice = priceService.goldPricePerGram
        }
        guard let price = currentPrice else { return nil }
        return (price - holding.avgCost) / holding.avgCost * 100
    }

    private func totalKRW(for assetClass: HoldingAssetClass) -> Double {
        store.holdings(for: assetClass).reduce(0) { $0 + (evalAmountKRW($1) ?? 0) }
    }

    private func formatKRW(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return (formatter.string(from: NSNumber(value: value)) ?? "0") + "원"
    }

    private func formatQuantity(_ q: Double, assetClass: HoldingAssetClass) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        let numStr = formatter.string(from: NSNumber(value: q)) ?? String(q)
        switch assetClass {
        case .gold: return "\(numStr)g"
        default: return "\(numStr)주"
        }
    }
}
